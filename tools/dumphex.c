#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <memory.h>
#include <unistd.h>
#include <stdlib.h>

typedef int bool;
#define true 1
#define false 0

bool byte_files = false;
bool strip_ending_zeros = true;
bool parse64bit = false;

unsigned int base = 0;
unsigned int size = (1<<16);

FILE *ifp;
char output_file[1024] = "aout";

int main(int argc, char *argv[]) {
    int i;
    ifp = stdin;

    i = 1;
    while (i < argc) {
        if (!strcmp(argv[i], "-byte"))
            byte_files = true;
        else if (!strcmp(argv[i], "-word"))
            byte_files = false;
        else if (!strcmp(argv[i], "-all"))
            strip_ending_zeros = false;
        else if (!strcmp(argv[i], "-strip"))
            strip_ending_zeros = true;
        else if (!strcmp(argv[i], "-base")) {
            base = strtoul(argv[i + 1], NULL, 0);
            ++i;
        } else if (!strcmp(argv[i], "-size")) {
            size = strtoul(argv[i + 1], NULL, 0);
            ++i;
        } else if (!strcmp(argv[i], "-o")) {
            strcpy(output_file, argv[i + 1]);
            ++i;
        } else if (!strcmp(argv[i], "-64")) {
            parse64bit = true;
        } else if (!strcmp(argv[i], "-i")) {
            ifp = fopen(argv[i + 1], "r");
            if (!ifp)
                printf("Cannot open: %s\n", argv[i + 1]);
            ++i;
        } else {
            printf("Can't parse: %s\n", argv[i]);
            printf("usage: [-64] -i file -o file -base number -size number -all -strip -byte -word\n");
            exit(1);
        }
        ++i;
    }      
    if (!ifp) {
        printf("Failed to open input\n");
        exit(2);
    }
    if (base != 0)
        fseek(ifp, base, SEEK_SET);

    unsigned char *data = malloc(size);
    memset(data, 0, size);
    int amount = fread(data, 1, size, ifp);
    if (ifp != stdin)
        fclose(ifp);

    int true_size = amount;
    while (data[true_size - 1] == 0 && true_size  > 0)
        --true_size;

    uint32_t *data32 = (uint32_t *) data;

    char output_file_full[1024];

    FILE *ofp;

    if (!byte_files) {
        strcpy(output_file_full, output_file);
        strcat(output_file_full, ".hex"); 
        ofp = fopen(output_file_full, "w");
        if (!ofp) {
            printf("Failure to create %s\n", output_file_full);
            exit(2);
        }
        i = 0;
        while (strip_ending_zeros ? (i < true_size) : (i < amount)) {
            fprintf(ofp, "%8.8x\n", data32[i / 4]);
            i += 4;
        }
        fclose(ofp);
    } else {
        if (parse64bit) {
            int byte = 0;
            for (byte = 0; byte < 8; byte++) {
                sprintf(output_file_full, "%s%d.hex", output_file, byte);
                ofp = fopen(output_file_full, "w");
                if (!ofp) {
                    printf("Failure to create %s\n", output_file_full);
                    exit(2);
                }
                i = 0;
                while (strip_ending_zeros ? (i < true_size) : (i < amount)) {
                    fprintf(ofp, "%2.2x\n", data[i + byte]);
                    i += 8;
                }
               fclose(ofp);
            }            
        } else {
            int byte = 0;
            for (byte = 0; byte < 4; byte++) {
                sprintf(output_file_full, "%s%d.hex", output_file, byte);
                ofp = fopen(output_file_full, "w");
                if (!ofp) {
                    printf("Failure to create %s\n", output_file_full);
                    exit(2);
                }
                i = 0;
                while (strip_ending_zeros ? (i < true_size) : (i < amount)) {
                    fprintf(ofp, "%2.2x\n", data[i + byte]);
                    i += 4;
                }
               fclose(ofp);
            }            
        }
    }
    return 0;
}

