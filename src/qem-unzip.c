/* sqlux-unzip
 *
 * (c) 2022 Graeme Gregory
 *
 * SPDX: Zlib
 */

#include <assert.h>
#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zip.h>

#include "q-emulator.h"
#include "qdos-file-header.h"
#include "sqlux_hexdump.h"

#pragma pack(push, 1)
typedef struct {
	uint32_t long_id;
	uint32_t extra_id;
	qdos_file_hdr qdos;
} zip_qdos_file_hdr;
#pragma pack(pop)

#define SWAP16(a)   ((((a)&0xff)<<8)|(((a)&0xff00)>>8))
#define SWAP32(a)   ((((a)&0xff)<<24)|(((a)&0xff00)<<8)|(((a)&0xff0000)>>8)|(((a)&0xff000000)>>24))

const q_emulator_hdr q_em_template = {
	.h_header = "]!QDOS File Header",
	.h_wordlen = 15,
	.f_access = 0,
	.f_type = 0,
	.f_datalen = 0,
};

int extract_zip(char *zipname)
{
	struct zip *zip;
	struct zip_file *zipfile;
	int fd, i, entries;
	zip_uint16_t x_len, x_id;
	const char *entryname;
	q_emulator_hdr q_emu_hdr;
	zip_qdos_file_hdr *zip_qdos_hdr;
	const uint8_t *extra_hdr;
	struct zip_stat zstat;

	printf("Opening Zip %s\n", zipname);

	zip = zip_open(zipname, 0, NULL);
	if (!zip) {
		fprintf(stderr, "Error opening zip file %s\n", zipname);
		return -1;
	}

	/* walk through all files stored in that zip */
	entries = zip_get_num_entries(zip, 0);

	for (i = 0; i < entries; i++) {
		entryname = zip_get_name(zip, i, 0);

		printf("Entry: %s\n", entryname);

		if (entryname[strlen(entryname)] == '/') {
			printf("Creating Directory %s\n", entryname);
			mkdir(entryname, 0777);
			continue;
		}

		zipfile = zip_fopen_index(zip, i, 0);
		if (!zipfile) {
			fprintf(stderr,
				"Error opening zip file %s, skipping it\n",
				entryname);
			continue;
		}

		zip_qdos_hdr = NULL;

		extra_hdr = zip_file_extra_field_get(zip, i, 0, &x_id, &x_len,
						     ZIP_FL_CENTRAL);
		if (x_id == 0xfb4a) {
			if (x_len != sizeof(zip_qdos_file_hdr))
				fprintf(stderr,
					"Warning extra entry size mismatch, ignoring it\n");
			else {
				zip_qdos_hdr = (zip_qdos_file_hdr *)(extra_hdr);
				sqlux_hexdump(&zip_qdos_hdr->qdos, sizeof(qdos_file_hdr));
			}
		}

		if (zip_stat_index(zip, i, 0, &zstat) != 0) {
			fprintf(stderr, "Error get file stat, skipping it\n");
			continue;
		}

		if (!(zstat.valid & ZIP_STAT_SIZE)) {
			fprintf(stderr,
				"Error file size unknown, skipping it\n");
			continue;
		}

		if (zip_qdos_hdr && (zstat.size != SWAP32(zip_qdos_hdr->qdos.f_length))) {
			printf("WARNING: qdos/zip file size mismatch\n");
		}

		// load file contents into memory
		char *buffer = (char *)malloc(zstat.size);
		if (zip_fread(zipfile, buffer, zstat.size) != zstat.size) {
			fprintf(stderr, "Error unzipping file %s, skipping it\n",
				entryname);
		}

		fd = open(entryname, O_RDWR | O_CREAT, 0664);
		if (fd < 0) {
			fprintf(stderr, "Could not create file %s.\n", entryname);
		} else {
			if (zip_qdos_hdr && zip_qdos_hdr->qdos.f_type) {
				memcpy(&q_emu_hdr, &q_em_template, sizeof(q_em_template));
				q_emu_hdr.f_type = zip_qdos_hdr->qdos.f_type;
				q_emu_hdr.f_datalen = zip_qdos_hdr->qdos.f_datalen;
				q_emu_hdr.f_res = zip_qdos_hdr->qdos.f_reserved;

				write(fd, &q_emu_hdr, QEMULATOR_SHORT_HEADER);
			}

			write(fd, buffer, zstat.size);

			close(fd);
		}

		if (buffer) {
			free(buffer);
			buffer = NULL;
		}
		zip_fclose(zipfile);
	}

	zip_close(zip);

	return 0;
}

int main(int argc, char **argv)
{
	int res = 0;

	/* for portability check our packing is working */
	assert(sizeof(q_emulator_hdr) == 44);
	assert(sizeof(qdos_file_hdr) == 64);
	assert(sizeof(zip_qdos_file_hdr) == 72);

	if (argc != 2) {
		printf("Usage: sqlux-unzip zipfile\n");
		return 0;
	}

	res = extract_zip(argv[1]);

	return res;
}
