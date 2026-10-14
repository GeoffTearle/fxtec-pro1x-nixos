/*
 * pro1x-xts-encrypt: encrypt a disk image the way dm-crypt does for a LUKS2 volume with
 * "aes-xts-plain64" and 512-byte sectors, without needing root or device-mapper.
 *
 *   pro1x-xts-encrypt [-d] KEYFILE OUTFILE OFFSET < input
 *
 * KEYFILE is the 64-byte volume key (the one given to `cryptsetup luksFormat
 * --volume-key-file`). The input is split into 512-byte sectors (the last one is padded
 * with zeros); sector N is encrypted with AES-256-XTS and the tweak (IV) "N as a 64-bit
 * little-endian number, zero padded to 16 bytes" (dm-crypt's "plain64"). The result is
 * written to OUTFILE, which must already exist, starting at byte OFFSET. With -d the
 * same is done in the other direction (used by the tests).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <openssl/evp.h>

#define SECTOR 512
#define CHUNK (4 * 1024 * 1024)

static int die(const char *what)
{
	fprintf(stderr, "pro1x-xts-encrypt: %s%s%s\n", what, errno ? ": " : "", errno ? strerror(errno) : "");
	return 1;
}

static ssize_t read_full(int fd, unsigned char *buf, size_t len)
{
	size_t got = 0;

	while (got < len) {
		ssize_t n = read(fd, buf + got, len - got);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0)
			break;
		got += n;
	}
	return got;
}

static int write_full_at(int fd, const unsigned char *buf, size_t len, off_t off)
{
	size_t done = 0;

	while (done < len) {
		ssize_t n = pwrite(fd, buf + done, len - done, off + done);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		done += n;
	}
	return 0;
}

int main(int argc, char **argv)
{
	int decrypt = 0, ai = 1;
	unsigned char key[64], *in, *out;
	EVP_CIPHER_CTX *ctx;
	off_t off, pos;
	uint64_t sector = 0;
	int kfd, ofd;
	ssize_t n;

	if (argc > 1 && !strcmp(argv[1], "-d")) {
		decrypt = 1;
		ai = 2;
	}
	if (argc - ai != 3) {
		fprintf(stderr, "usage: %s [-d] KEYFILE OUTFILE OFFSET < input\n", argv[0]);
		return 2;
	}

	errno = 0;
	kfd = open(argv[ai], O_RDONLY);
	if (kfd < 0 || read_full(kfd, key, sizeof(key)) != sizeof(key))
		return die("cannot read a 64-byte key");
	close(kfd);

	off = strtoll(argv[ai + 2], NULL, 10);
	if (off < 0 || off % SECTOR)
		return die("OFFSET must be a multiple of 512");
	ofd = open(argv[ai + 1], O_WRONLY);
	if (ofd < 0)
		return die("cannot open OUTFILE (it must exist)");

	in = malloc(CHUNK);
	out = malloc(CHUNK);
	ctx = EVP_CIPHER_CTX_new();
	if (!in || !out || !ctx)
		return die("out of memory");
	if (!EVP_CipherInit_ex(ctx, EVP_aes_256_xts(), NULL, key, NULL, !decrypt))
		return die("EVP_CipherInit_ex failed (key1 == key2?)");

	pos = off;
	while ((n = read_full(0, in, CHUNK)) > 0) {
		size_t len = ((size_t)n + SECTOR - 1) / SECTOR * SECTOR, i;

		memset(in + n, 0, len - n);
		for (i = 0; i < len; i += SECTOR, sector++) {
			unsigned char iv[16] = { 0 };
			int outl = 0, k;

			for (k = 0; k < 8; k++)
				iv[k] = (sector >> (8 * k)) & 0xff;
			if (!EVP_CipherInit_ex(ctx, NULL, NULL, NULL, iv, !decrypt) ||
			    !EVP_CipherUpdate(ctx, out + i, &outl, in + i, SECTOR) || outl != SECTOR)
				return die("encryption failed");
		}
		if (write_full_at(ofd, out, len, pos))
			return die("write failed");
		pos += len;
	}
	if (n < 0)
		return die("read failed");
	if (close(ofd))
		return die("close failed");
	return 0;
}
