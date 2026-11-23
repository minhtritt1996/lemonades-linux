/*
 * Phase 2 early init (PID 1) for OnePlus 9R (lemonades / SM8250) Denial Mobile.
 * - Mounts /proc, /sys, /dev, /sys/kernel/config, /sys/fs/pstore
 * - Dumps any pstore/ramoops entries to /dev/kmsg
 * - Sets up USB gadget: CDC-ACM (/dev/ttyGS0 console) + CDC-NCM (usb0 172.16.42.1/24)
 * - Detects active A/B slot (_a / _b) from /proc/cmdline and mounts firmware partitions
 * - Mounts Denial rootfs on userdata/denial/linux (ext4) and switches root to systemd
 *   (keeps /dev/ttyGS0 rescue console alive in a child process)
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/reboot.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/klog.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

static void log_kmsg(const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (n <= 0)
		return;
	size_t len = (size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1;
	int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (fd >= 0) {
		if (write(fd, buf, len) < 0) {}
		close(fd);
	}
	if (write(STDOUT_FILENO, buf, len) < 0) {}
}

static void fd_printf(int fd, const char *fmt, ...)
{
	char buf[4096];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (n > 0) {
		size_t len = (size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1;
		if (write(fd, buf, len) < 0) {}
	}
}

static int read_file_str(const char *path, char *buf, size_t len)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	ssize_t n = read(fd, buf, len - 1);
	close(fd);
	if (n < 0)
		return -1;
	buf[n] = '\0';
	return (int)n;
}

static int write_file_str(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	ssize_t n = write(fd, val, strlen(val));
	close(fd);
	return n < 0 ? -1 : 0;
}

static void mkdir_p(const char *path)
{
	char tmp[256];
	snprintf(tmp, sizeof(tmp), "%s", path);
	for (char *p = tmp + 1; *p; p++) {
		if (*p == '/') {
			*p = '\0';
			mkdir(tmp, 0755);
			*p = '/';
		}
	}
	mkdir(tmp, 0755);
}

static int cmdline_has(const char *flag)
{
	char cmdline[2048];
	if (read_file_str("/proc/cmdline", cmdline, sizeof(cmdline)) <= 0)
		return 0;
	return strstr(cmdline, flag) != NULL;
}

static void parse_slot_suffix(char *out, size_t len)
{
	char cmdline[2048];
	snprintf(out, len, "_a");
	if (read_file_str("/proc/cmdline", cmdline, sizeof(cmdline)) <= 0)
		return;

	const char *keys[] = {"androidboot.slot_suffix=", "slot_suffix="};
	for (size_t i = 0; i < 2; i++) {
		char *p = strstr(cmdline, keys[i]);
		if (p) {
			p += strlen(keys[i]);
			size_t j = 0;
			while (p[j] && p[j] != ' ' && p[j] != '\n' && j + 1 < len) {
				out[j] = p[j];
				j++;
			}
			if (j > 0)
				out[j] = '\0';
			return;
		}
	}
}

static int find_part(const char *name, char *dev, size_t devlen)
{
	DIR *d = opendir("/sys/class/block");
	struct dirent *e;
	if (!d)
		return -1;
	while ((e = readdir(d)) != NULL) {
		char path[300], buf[1024];
		if (e->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path), "/sys/class/block/%s/uevent", e->d_name);
		if (read_file_str(path, buf, sizeof(buf)) <= 0)
			continue;
		char *p = strstr(buf, "PARTNAME=");
		if (!p || strncmp(p + 9, name, strlen(name)) != 0 ||
		    (p[9 + strlen(name)] != '\n' && p[9 + strlen(name)] != '\0'))
			continue;
		p = strstr(buf, "DEVNAME=");
		if (!p)
			continue;
		snprintf(dev, devlen, "/dev/%.*s", (int)strcspn(p + 8, "\n"), p + 8);
		closedir(d);
		return 0;
	}
	closedir(d);
	return -1;
}

static void dump_pstore(void)
{
	DIR *d = opendir("/sys/fs/pstore");
	struct dirent *de;
	if (!d)
		return;
	while ((de = readdir(d)) != NULL) {
		if (de->d_name[0] == '.')
			continue;
		log_kmsg("lemonades-init: found pstore entry: %s\n", de->d_name);
	}
	closedir(d);
}

static int net_if_up_ip(const char *ifname, const char *ip, const char *mask)
{
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0)
		return -1;

	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", ifname);

	struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
	sin->sin_family = AF_INET;
	inet_pton(AF_INET, ip, &sin->sin_addr);
	ioctl(s, SIOCSIFADDR, &ifr);

	inet_pton(AF_INET, mask, &sin->sin_addr);
	ioctl(s, SIOCSIFNETMASK, &ifr);

	if (ioctl(s, SIOCGIFFLAGS, &ifr) == 0) {
		ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
		ioctl(s, SIOCSIFFLAGS, &ifr);
	}
	close(s);
	return 0;
}

static void setup_usb_gadget(void)
{
	const char *g = "/sys/kernel/config/usb_gadget/lemonades";
	char udc[256] = {0};

	mkdir("/sys/kernel/config/usb_gadget", 0755);
	mkdir(g, 0755);
	write_file_str("/sys/kernel/config/usb_gadget/lemonades/idVendor", "0x1d6b");
	write_file_str("/sys/kernel/config/usb_gadget/lemonades/idProduct", "0x0104");
	write_file_str("/sys/kernel/config/usb_gadget/lemonades/bcdUSB", "0x0200");
	write_file_str("/sys/kernel/config/usb_gadget/lemonades/bcdDevice", "0x0100");

	mkdir("/sys/kernel/config/usb_gadget/lemonades/strings/0x409", 0755);
	write_file_str("/sys/kernel/config/usb_gadget/lemonades/strings/0x409/manufacturer", "Denial");
	write_file_str("/sys/kernel/config/usb_gadget/lemonades/strings/0x409/product", "OnePlus 9R (lemonades)");
	write_file_str("/sys/kernel/config/usb_gadget/lemonades/strings/0x409/serialnumber", "lemonades-001");

	mkdir("/sys/kernel/config/usb_gadget/lemonades/configs/c.1", 0755);
	mkdir("/sys/kernel/config/usb_gadget/lemonades/configs/c.1/strings/0x409", 0755);
	write_file_str("/sys/kernel/config/usb_gadget/lemonades/configs/c.1/strings/0x409/configuration", "ACM+NCM");

	mkdir("/sys/kernel/config/usb_gadget/lemonades/functions/acm.GS0", 0755);
	mkdir("/sys/kernel/config/usb_gadget/lemonades/functions/ncm.usb0", 0755);

	if (symlink("/sys/kernel/config/usb_gadget/lemonades/functions/acm.GS0",
		    "/sys/kernel/config/usb_gadget/lemonades/configs/c.1/acm.GS0") < 0 && errno != EEXIST)
		log_kmsg("lemonades-init: failed to link acm.GS0\n");

	if (symlink("/sys/kernel/config/usb_gadget/lemonades/functions/ncm.usb0",
		    "/sys/kernel/config/usb_gadget/lemonades/configs/c.1/ncm.usb0") < 0 && errno != EEXIST)
		log_kmsg("lemonades-init: failed to link ncm.usb0\n");

	for (int i = 0; i < 30; i++) {
		DIR *d = opendir("/sys/class/udc");
		if (d) {
			struct dirent *de;
			while ((de = readdir(d)) != NULL) {
				if (de->d_name[0] != '.') {
					snprintf(udc, sizeof(udc), "%.*s", (int)(sizeof(udc) - 1), de->d_name);
					break;
				}
			}
			closedir(d);
		}
		if (udc[0])
			break;
		usleep(200000);
	}

	if (!udc[0]) {
		log_kmsg("lemonades-init: no UDC found (USB gadget skipped)\n");
		return;
	}

	if (write_file_str("/sys/kernel/config/usb_gadget/lemonades/UDC", udc) == 0) {
		log_kmsg("lemonades-init: USB gadget ACM+NCM bound to %s\n", udc);
		for (int i = 0; i < 20; i++) {
			if (access("/sys/class/net/usb0", F_OK) == 0) {
				net_if_up_ip("usb0", "172.16.42.1", "255.255.255.0");
				log_kmsg("lemonades-init: usb0 up at 172.16.42.1/24\n");
				break;
			}
			usleep(100000);
		}
	}
}

static void mount_slot_firmware(const char *slot)
{
	char part[64], dev[64];

	snprintf(part, sizeof(part), "modem%s", slot);
	if (find_part(part, dev, sizeof(dev)) == 0) {
		mkdir_p("/mnt/modem");
		if (mount(dev, "/mnt/modem", "vfat", MS_RDONLY, NULL) == 0 ||
		    mount(dev, "/mnt/modem", "ext4", MS_RDONLY, NULL) == 0) {
			mkdir_p("/lib/firmware/qcom/sm8250/slpi");
			if (access("/mnt/modem/image/slpi.mdt", F_OK) == 0)
				mount("/mnt/modem/image", "/lib/firmware/qcom/sm8250/slpi",
				      NULL, MS_BIND, NULL);
			log_kmsg("lemonades-init: mounted %s (%s)\n", part, dev);
		}
	}

	snprintf(part, sizeof(part), "dsp%s", slot);
	if (find_part(part, dev, sizeof(dev)) == 0) {
		mkdir_p("/mnt/dsp");
		if (mount(dev, "/mnt/dsp", "ext4", MS_RDONLY, NULL) == 0)
			log_kmsg("lemonades-init: mounted %s (%s)\n", part, dev);
	}

	snprintf(part, sizeof(part), "bluetooth%s", slot);
	if (find_part(part, dev, sizeof(dev)) == 0) {
		mkdir_p("/mnt/bluetooth");
		if (mount(dev, "/mnt/bluetooth", "vfat", MS_RDONLY, NULL) == 0 ||
		    mount(dev, "/mnt/bluetooth", "ext4", MS_RDONLY, NULL) == 0) {
			mkdir_p("/lib/firmware/qca");
			if (access("/mnt/bluetooth/image", F_OK) == 0)
				mount("/mnt/bluetooth/image", "/lib/firmware/qca", NULL, MS_BIND, NULL);
			log_kmsg("lemonades-init: mounted %s (%s)\n", part, dev);
		}
	}
}

static void cmd_cat(int fd, const char *path)
{
	int f = open(path, O_RDONLY | O_CLOEXEC);
	char buf[2048];
	ssize_t n;
	if (f < 0) {
		fd_printf(fd, "cat: %s: %s\n", path, strerror(errno));
		return;
	}
	while ((n = read(f, buf, sizeof(buf))) > 0) {
		if (write(fd, buf, (size_t)n) < 0)
			break;
	}
	close(f);
	fd_printf(fd, "\n");
}

static void cmd_ls(int fd, const char *path)
{
	DIR *d = opendir(path);
	struct dirent *de;
	if (!d) {
		fd_printf(fd, "ls: %s: %s\n", path, strerror(errno));
		return;
	}
	while ((de = readdir(d)) != NULL) {
		if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
			continue;
		fd_printf(fd, "%s\n", de->d_name);
	}
	closedir(d);
}

static void handle_cmd(int fd, char *line)
{
	while (*line == ' ' || *line == '\t')
		line++;
	if (!*line)
		return;

	if (strcmp(line, "help") == 0) {
		fd_printf(fd, "Commands: help, uname, dmesg, pstore, ls [dir], cat <file>, sh <cmd>, reboot, bootloader, poweroff\n");
	} else if (strcmp(line, "uname") == 0) {
		struct utsname u;
		if (uname(&u) == 0)
			fd_printf(fd, "%s %s %s %s\n", u.sysname, u.release, u.version, u.machine);
	} else if (strcmp(line, "dmesg") == 0) {
		int sz = klogctl(10, NULL, 0);
		if (sz <= 0)
			sz = 65536;
		char *buf = malloc((size_t)sz + 1);
		if (buf) {
			int n = klogctl(3, buf, sz);
			if (n > 0 && write(fd, buf, (size_t)n) < 0) {}
			free(buf);
		}
		fd_printf(fd, "\n");
	} else if (strcmp(line, "pstore") == 0) {
		cmd_ls(fd, "/sys/fs/pstore");
	} else if (strcmp(line, "ls") == 0) {
		cmd_ls(fd, "/");
	} else if (strncmp(line, "ls ", 3) == 0) {
		cmd_ls(fd, line + 3);
	} else if (strncmp(line, "cat ", 4) == 0) {
		cmd_cat(fd, line + 4);
	} else if (strncmp(line, "sh ", 3) == 0) {
		pid_t pid = fork();
		if (pid == 0) {
			dup2(fd, 0);
			dup2(fd, 1);
			dup2(fd, 2);
			execl("/bin/sh", "sh", "-c", line + 3, NULL);
			_exit(127);
		} else if (pid > 0) {
			waitpid(pid, NULL, 0);
		} else {
			fd_printf(fd, "fork: %s\n", strerror(errno));
		}
	} else if (strcmp(line, "bootloader") == 0 || strcmp(line, "reboot") == 0) {
		fd_printf(fd, "Rebooting to bootloader...\n");
		sync();
		syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
			LINUX_REBOOT_CMD_RESTART2, "bootloader");
	} else if (strcmp(line, "poweroff") == 0) {
		fd_printf(fd, "Powering off...\n");
		sync();
		reboot(LINUX_REBOOT_CMD_POWER_OFF);
	} else {
		fd_printf(fd, "unknown: %s (try 'help')\n", line);
	}
}

static void console_loop(void)
{
	for (;;) {
		int fd = open("/dev/ttyGS0", O_RDWR | O_NOCTTY);
		if (fd < 0) {
			sleep(1);
			continue;
		}
		struct termios tio;
		if (tcgetattr(fd, &tio) == 0) {
			tio.c_lflag |= ICANON | ECHO;
			tio.c_iflag |= ICRNL;
			tio.c_oflag |= OPOST | ONLCR;
			tcsetattr(fd, TCSANOW, &tio);
		}
		fd_printf(fd, "\n=== lemonades-linux console (/dev/ttyGS0, usb0=172.16.42.1) ===\n");
		fd_printf(fd, "lemonades# ");

		char line[512];
		size_t pos = 0;
		char ch;
		while (read(fd, &ch, 1) == 1) {
			if (ch == '\r' || ch == '\n') {
				line[pos] = '\0';
				handle_cmd(fd, line);
				pos = 0;
				fd_printf(fd, "lemonades# ");
			} else if (pos + 1 < sizeof(line)) {
				line[pos++] = ch;
			}
		}
		close(fd);
		sleep(1);
	}
}

/*
 * Guarantee remote access across reboots: sshd must listen on every address
 * (including tailscale0) and root's authorized_keys must survive rootfs
 * upgrades or a rewritten sshd_config.d.  Runs before switch_root so the
 * drop-in exists the first time sshd starts.
 */
static void ensure_ssh_access(void)
{
	static const char conf[] =
		"# Written by the lemonades initramfs on every boot.\n"
		"ListenAddress 0.0.0.0\n"
		"PermitRootLogin yes\n";
	static const char key[] = "/newroot/root/.ssh/authorized_keys";
	static const char backup[] = "/newroot/etc/lemonades/authorized_keys";
	char buf[8192];
	int fd, n;

	mkdir_p("/newroot/etc/ssh/sshd_config.d");
	fd = open("/newroot/etc/ssh/sshd_config.d/99-lemonades.conf",
		  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0) {
		log_kmsg("lemonades-init: cannot write sshd drop-in: %s\n", strerror(errno));
	} else {
		if (write(fd, conf, sizeof(conf) - 1) < 0) {}
		close(fd);
	}

	mkdir_p("/newroot/root/.ssh");
	if (chmod("/newroot/root/.ssh", 0700) != 0) {}

	fd = open(key, O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		n = read(fd, buf, sizeof(buf));
		close(fd);
		if (n > 0) {
			mkdir_p("/newroot/etc/lemonades");
			int bfd = open(backup, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
			if (bfd >= 0) {
				if (write(bfd, buf, n) < 0) {}
				close(bfd);
			}
		}
		if (chmod(key, 0600) != 0) {}
	} else {
		fd = open(backup, O_RDONLY | O_CLOEXEC);
		if (fd < 0) {
			log_kmsg("lemonades-init: no root authorized_keys or backup\n");
		} else {
			n = read(fd, buf, sizeof(buf));
			close(fd);
			if (n > 0) {
				int kfd = open(key, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
				if (kfd >= 0) {
					if (write(kfd, buf, n) < 0) {}
					close(kfd);
				}
				log_kmsg("lemonades-init: restored root authorized_keys (%d bytes)\n", n);
			}
		}
	}

	log_kmsg("lemonades-init: sshd drop-in ensured (ListenAddress 0.0.0.0)\n");
}

static void write_newroot_file(const char *path, const char *content, size_t len)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		return;
	if (write(fd, content, len) < 0) {}
	close(fd);
}

/*
 * Ensure ALSA UCM2 profiles (Stereo Speakers via TFA9874 + DisplayPort/HDMI
 * Audio) and WirePlumber S16LE/non-mmap rules exist in /newroot so audio works
 * out of the box even after a fresh userdata flash.
 */
static void ensure_audio_config(void)
{
	static const char ucm_card[] =
		"Syntax 3\n\n"
		"SectionUseCase.\"HiFi\" {\n"
		"\tFile \"/Qualcomm/sm8250/OnePlus9R-HiFi.conf\"\n"
		"\tComment \"HiFi Quality Music\"\n"
		"}\n";
	static const char ucm_hifi[] =
		"SectionVerb {\n"
		"\tEnableSequence [\n"
		"\t\tcset \"name='TERT_MI2S_RX Audio Mixer MultiMedia1' 1\"\n"
		"\t\tcset \"name='DISPLAY_PORT_RX Audio Mixer MultiMedia2' 1\"\n"
		"\t]\n\n"
		"\tDisableSequence [\n"
		"\t\tcset \"name='TERT_MI2S_RX Audio Mixer MultiMedia1' 0\"\n"
		"\t\tcset \"name='DISPLAY_PORT_RX Audio Mixer MultiMedia2' 0\"\n"
		"\t]\n\n"
		"\tValue {\n"
		"\t\tTQ \"HiFi\"\n"
		"\t}\n"
		"}\n\n"
		"SectionDevice.\"Speaker\" {\n"
		"\tComment \"Stereo Speakers\"\n\n"
		"\tValue {\n"
		"\t\tPlaybackPriority 200\n"
		"\t\tPlaybackPCM \"hw:${CardId},0\"\n"
		"\t\tPlaybackRate 48000\n"
		"\t\tPlaybackChannels 2\n"
		"\t}\n"
		"}\n\n"
		"SectionDevice.\"HDMI\" {\n"
		"\tComment \"DisplayPort / HDMI Output\"\n\n"
		"\tValue {\n"
		"\t\tPlaybackPriority 100\n"
		"\t\tPlaybackPCM \"hw:${CardId},1\"\n"
		"\t\tPlaybackRate 48000\n"
		"\t\tPlaybackChannels 2\n"
		"\t\tJackControl \"DP0 Jack\"\n"
		"\t}\n"
		"}\n";
	static const char wp_rule[] =
		"# Written by lemonades initramfs: q6asm-dai needs S16LE and RW_INTERLEAVED.\n"
		"monitor.alsa.rules = [\n"
		"  {\n"
		"    matches = [\n"
		"      { node.name = \"~alsa_output.platform-sound.*\" }\n"
		"    ]\n"
		"    actions = {\n"
		"      update-props = {\n"
		"        audio.format = \"S16LE\"\n"
		"        audio.rate = 48000\n"
		"        audio.allowed-rates = [ 48000 ]\n"
		"        api.alsa.period-size = 1024\n"
		"        api.alsa.period-num = 4\n"
		"        api.alsa.headroom = 1024\n"
		"        api.alsa.disable-mmap = true\n"
		"      }\n"
		"    }\n"
		"  }\n"
		"]\n";

	mkdir_p("/newroot/usr/share/alsa/ucm2/Qualcomm/sm8250");
	mkdir_p("/newroot/usr/share/alsa/ucm2/conf.d/sm8250");
	write_newroot_file("/newroot/usr/share/alsa/ucm2/Qualcomm/sm8250/SM8250-OnePlus-9R.conf",
			   ucm_card, sizeof(ucm_card) - 1);
	write_newroot_file("/newroot/usr/share/alsa/ucm2/Qualcomm/sm8250/OnePlus9R-HiFi.conf",
			   ucm_hifi, sizeof(ucm_hifi) - 1);
	unlink("/newroot/usr/share/alsa/ucm2/Qualcomm/sm8250/OnePlus9R-HDMI.conf");
	unlink("/newroot/usr/share/alsa/ucm2/conf.d/sm8250/SM8250-OnePlus-9R.conf");
	if (symlink("../../Qualcomm/sm8250/SM8250-OnePlus-9R.conf",
		    "/newroot/usr/share/alsa/ucm2/conf.d/sm8250/SM8250-OnePlus-9R.conf") != 0) {}

	mkdir_p("/newroot/etc/wireplumber/wireplumber.conf.d");
	write_newroot_file("/newroot/etc/wireplumber/wireplumber.conf.d/51-lemonades-audio.conf",
			   wp_rule, sizeof(wp_rule) - 1);
	log_kmsg("lemonades-init: ALSA UCM2 + WirePlumber S16LE rules ensured\n");
}

/*
 * Droidloom needs one contiguous subordinate UID/GID range for root (the cell
 * maps 300000..399999).  /etc/subuid and /etc/subgid ship empty on this image,
 * and a torn append leaves NUL padding that the runtime's parser rejects, so
 * normalise both files before systemd starts.
 */
static void ensure_subid_file(const char *path, const char *range)
{
	char buf[4096];
	ssize_t n = 0;
	size_t raw_len, len;
	int fd, changed = 0;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		n = read(fd, buf, sizeof(buf) - 64);
		close(fd);
	}
	if (n < 0)
		n = 0;
	buf[n] = '\0';
	raw_len = strlen(buf);
	len = raw_len;
	if (len != (size_t)n)
		changed = 1;	/* NUL padding from a torn append */
	if (len && buf[len - 1] != '\n') {
		buf[len++] = '\n';
		buf[len] = '\0';
		changed = 1;
	}
	if (!strstr(buf, range)) {
		size_t rl = strlen(range);

		if (len + rl + 2 > sizeof(buf)) {
			len = 0;
			buf[0] = '\0';
		}
		memcpy(buf + len, range, rl);
		len += rl;
		buf[len++] = '\n';
		buf[len] = '\0';
		changed = 1;
	}
	if (!changed)
		return;

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0) {
		log_kmsg("lemonades-init: cannot write %s: %s\n", path, strerror(errno));
		return;
	}
	if (write(fd, buf, len) < 0) {}
	close(fd);
}

static void ensure_subid_ranges(void)
{
	ensure_subid_file("/newroot/etc/subuid", "root:300000:100000");
	ensure_subid_file("/newroot/etc/subgid", "root:300000:100000");
	log_kmsg("lemonades-init: root subordinate UID/GID range ensured\n");
}

static int try_switch_root(void)
{
	static const char *const parts[] = {"denial", "linux", "userdata"};
	char dev[64];
	int found = 0;

	/* Wait up to 10s for UFS block devices to enumerate */
	for (int t = 0; t < 50 && !found; t++) {
		for (size_t i = 0; i < 3; i++) {
			if (find_part(parts[i], dev, sizeof(dev)) == 0) {
				found = 1;
				break;
			}
		}
		if (!found)
			usleep(200000);
	}

	if (!found) {
		log_kmsg("lemonades-init: no denial/linux/userdata partition found\n");
		return -1;
	}

	mkdir_p("/newroot");
	if (mount(dev, "/newroot", "ext4", 0, NULL) != 0) {
		log_kmsg("lemonades-init: mount %s (ext4) failed: %s\n", dev, strerror(errno));
		return -1;
	}

	const char *init_bin = NULL;
	if (access("/newroot/usr/lib/systemd/systemd", X_OK) == 0)
		init_bin = "/usr/lib/systemd/systemd";
	else if (access("/newroot/sbin/init", X_OK) == 0)
		init_bin = "/sbin/init";

	if (!init_bin) {
		log_kmsg("lemonades-init: %s has no systemd/init, staying in initramfs\n", dev);
		umount("/newroot");
		return -1;
	}

	log_kmsg("lemonades-init: switching root to %s (%s)\n", dev, init_bin);

	mkdir_p("/newroot/run");
	mount("tmpfs", "/newroot/run", "tmpfs", 0, "mode=0755");
	mkdir_p("/newroot/run/systemd/system/denial.service.d");
	{
		int gfd = open("/newroot/run/systemd/system/denial.service.d/10-lemonades-gpu.conf",
			       O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
		if (gfd >= 0) {
			static const char cfg[] = "[Service]\nEnvironment=DENIAL_RENDER_DEVICE=/dev/dri/renderD128\n";
			if (write(gfd, cfg, sizeof(cfg) - 1) < 0) {}
			close(gfd);
		}
	}

	ensure_ssh_access();
	ensure_subid_ranges();
	ensure_audio_config();

	/* Merge /lib/firmware (initramfs) + /newroot/usr/lib/firmware via read-only overlay */
	if (access("/newroot/usr/lib/firmware", F_OK) == 0) {
		if (mount("overlay", "/newroot/usr/lib/firmware", "overlay", MS_RDONLY,
			  "lowerdir=/lib/firmware:/newroot/usr/lib/firmware") != 0) {
			mount("/lib/firmware", "/newroot/usr/lib/firmware", NULL, MS_BIND | MS_REC, NULL);
		} else {
			if (access("/lib/firmware/qca", F_OK) == 0)
				mount("/lib/firmware/qca", "/newroot/usr/lib/firmware/qca",
				      NULL, MS_BIND, NULL);
			if (access("/lib/firmware/qcom/sm8250/slpi/slpi.mdt", F_OK) == 0)
				mount("/lib/firmware/qcom/sm8250/slpi",
				      "/newroot/usr/lib/firmware/qcom/sm8250/slpi",
				      NULL, MS_BIND, NULL);
		}
		mount("/newroot/usr/lib/firmware", "/lib/firmware", NULL, MS_BIND | MS_REC, NULL);
	} else if (access("/newroot/lib/firmware", F_OK) == 0) {
		mount("/lib/firmware", "/newroot/lib/firmware", NULL, MS_BIND | MS_REC, NULL);
	}

	/* Rebind Wi-Fi (if not yet bound) and Bluetooth (to pick up /lib/firmware/qca from bluetooth_a) */
	if (access("/sys/bus/pci/drivers/ath11k_pci/0000:01:00.0", F_OK) != 0) {
		write_file_str("/sys/bus/pci/drivers/ath11k_pci/unbind", "0000:01:00.0");
		write_file_str("/sys/bus/pci/drivers/ath11k_pci/bind", "0000:01:00.0");
	}
	/* Rebind Bluetooth in background so QCA UART retry timeouts do not stall boot by ~33s */
	if (fork() == 0) {
		write_file_str("/sys/bus/serial/drivers/hci_uart_qca/unbind", "serial0-0");
		write_file_str("/sys/bus/serial/drivers/hci_uart_qca/bind", "serial0-0");
		_exit(0);
	}

	/* Start SLPI remoteproc if offline (firmware mounted from modem_<slot>) */
	{
		DIR *rd = opendir("/sys/class/remoteproc");
		if (rd) {
			struct dirent *de;
			while ((de = readdir(rd)) != NULL) {
				char path[300], name[32] = {0}, state[32] = {0};
				int nfd;
				if (de->d_name[0] == '.')
					continue;
				snprintf(path, sizeof(path), "/sys/class/remoteproc/%s/name", de->d_name);
				nfd = open(path, O_RDONLY | O_CLOEXEC);
				if (nfd >= 0) {
					ssize_t nr = read(nfd, name, sizeof(name) - 1);
					close(nfd);
					if (nr > 0 && strncmp(name, "slpi", 4) == 0) {
						snprintf(path, sizeof(path), "/sys/class/remoteproc/%s/state", de->d_name);
						nfd = open(path, O_RDONLY | O_CLOEXEC);
						if (nfd >= 0) {
							ssize_t sr = read(nfd, state, sizeof(state) - 1);
							close(nfd);
							if (sr > 0 && strncmp(state, "running", 7) != 0)
								write_file_str(path, "start");
						}
					}
				}
			}
			closedir(rd);
		}
	}

	/* Bind /lib/modules into /newroot (pure RAM bind-mount) */
	if (access("/lib/modules", F_OK) == 0) {
		if (access("/newroot/usr/lib/modules", F_OK) == 0)
			mount("/lib/modules", "/newroot/usr/lib/modules", NULL, MS_BIND | MS_REC, NULL);
		else if (access("/newroot/lib/modules", F_OK) == 0)
			mount("/lib/modules", "/newroot/lib/modules", NULL, MS_BIND | MS_REC, NULL);
	}

	static const char *const dirs[] = {"dev", "proc", "sys"};
	for (size_t i = 0; i < 3; i++) {
		char src[32], dst[64];
		snprintf(src, sizeof(src), "/%s", dirs[i]);
		snprintf(dst, sizeof(dst), "/newroot/%s", dirs[i]);
		mkdir_p(dst);
		mount(src, dst, NULL, MS_BIND | MS_REC, NULL);
	}

	if (chdir("/newroot") != 0 || mount(".", "/", NULL, MS_MOVE, NULL) != 0 || chroot(".") != 0) {
		log_kmsg("lemonades-init: switch_root failed: %s\n", strerror(errno));
		return -1;
	}
	if (chdir("/") != 0) {}

	/* Keep /dev/ttyGS0 rescue console alive in background (inside new rootfs) */
	if (fork() == 0) {
		console_loop();
		_exit(0);
	}

	char *const argv[] = {(char *)init_bin, NULL};
	execv(init_bin, argv);
	log_kmsg("lemonades-init: execv(%s) failed: %s\n", init_bin, strerror(errno));
	return -1;
}

static void paint_fb0(void)
{
	int fd = open("/dev/fb0", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		log_kmsg("lemonades-init: /dev/fb0 not present: %s\n", strerror(errno));
		return;
	}
	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) == 0 &&
	    ioctl(fd, FBIOGET_FSCREENINFO, &finfo) == 0 &&
	    finfo.smem_len > 0) {
		void *fb = mmap(NULL, finfo.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		if (fb != MAP_FAILED) {
			/* Top 120px green bar so screen activity is unmistakable */
			unsigned int *px = (unsigned int *)fb;
			unsigned int stride_px = finfo.line_length / 4;
			unsigned int rows = vinfo.yres < 120 ? vinfo.yres : 120;
			for (unsigned int y = 0; y < rows; y++) {
				for (unsigned int x = 0; x < vinfo.xres; x++)
					px[y * stride_px + x] = 0xFF00C853;
			}
			munmap(fb, finfo.smem_len);
			log_kmsg("lemonades-init: painted /dev/fb0 (%ux%u)\n", vinfo.xres, vinfo.yres);
		}
	}
	close(fd);
}

int main(void)
{
	char slot[16];

	mount("proc", "/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL);
	mount("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NOEXEC | MS_NODEV, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
	mount("configfs", "/sys/kernel/config", "configfs", 0, NULL);
	mount("pstore", "/sys/fs/pstore", "pstore", 0, NULL);

	log_kmsg("\n=== lemonades-linux (OnePlus 9R / SM8250) Phase 2 init ===\n");
	paint_fb0();
	dump_pstore();
	parse_slot_suffix(slot, sizeof(slot));
	log_kmsg("lemonades-init: active slot = %s\n", slot);

	setup_usb_gadget();
	mount_slot_firmware(slot);

	if (!cmdline_has("lemonades.noswitch"))
		try_switch_root();

	console_loop();
	return 0;
}
