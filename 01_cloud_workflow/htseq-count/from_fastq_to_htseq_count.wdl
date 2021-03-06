workflow MyBestWorkflow {
    # IMPORTANT:
    # This script only handles fastq. fastqList is not handled.

    # FILE INFO
    # the sample_id stores some raw information of the samples
    # The base_file_name is the actual, concise, and actual sample_name throughout the code.
    String base_file_name

    # Required for fastq
    File fastq_r1
    File? fastq_r2

    # Handle single_ended or pair_ended?
    Boolean? single_ended
    Boolean whether_single_end = select_first([single_ended, false])

    # Process input args: usually the library prepation for strandness is "RF".
    String? strandness

    # REFERENCE FILES for HiSAT2
    File hisat_index_file
    Array[String] hisat_index = read_lines(hisat_index_file)
    String hisat_prefix

    # GTF file is needed by HTSeq-count
    File ref_gtf

    # These two locations on Google Drive Bucket are used to collect results,
    # namely, bam files and htseq-count text files.
    String sorted_bam_result_directory
    String duplicates_metrics_result_directory
    String htseq_count_result_directory

    call StringToFile {
        input:
            sample_name = base_file_name,
            fastq_r1_string = fastq_r1,
            fastq_r2_string = fastq_r2
    }

    call FastqToSam {
        input:
            fastq_list_files = StringToFile.fastq_list_files,
            single_end_argument = whether_single_end,
            sample_name = base_file_name,
            hisat_index = hisat_index,
            hisat_prefix = hisat_prefix,
            strandness = strandness
    }

    call SamToCoordinateSortedBam {
        input:
            sample_name = base_file_name,
            input_sam = FastqToSam.initially_mapped_sam
    }

    call PicardMarkDuplicates {
        input:
            sample_name = base_file_name,
            input_bam = SamToCoordinateSortedBam.coordinate_sorted_bam
    }

    call BamToQuerynameSortedBam {
        input:
            sample_name = base_file_name,
            input_bam = PicardMarkDuplicates.duplicates_removed_bam
    }

    call CallHtseqCount {
        input:
            sample_name = base_file_name,
            input_bam = BamToQuerynameSortedBam.queryname_sorted_bam,
            gtf_annotation = ref_gtf,
            strandness = strandness
    }

    call CompressResults {
        input:
            sample_name = base_file_name,
            htseq_count_txt = CallHtseqCount.htseq_count_txt
    }

    call CollectResultFiles {
        input:
            sorted_bam = SamToCoordinateSortedBam.coordinate_sorted_bam,
            duplicates_metrics_txt = PicardMarkDuplicates.duplicates_metrics_txt,
            htseq_count_compressed_file = CompressResults.htseq_count_compressed_file,
            sorted_bam_result_directory = sorted_bam_result_directory,
            htseq_count_result_directory = htseq_count_result_directory,
            duplicates_metrics_result_directory = duplicates_metrics_result_directory
    }

    # Output files of the workflows.
    output {
        File sorted_bam = SamToCoordinateSortedBam.coordinate_sorted_bam
        File duplicates_metrics_txt = PicardMarkDuplicates.duplicates_metrics_txt
        File htseq_count_txt = CallHtseqCount.htseq_count_txt
    }
}

task StringToFile {
    String sample_name
    String fastq_r1_string
    String? fastq_r2_string

    command {
        echo "${fastq_r1_string}" | tr ";" "\n" > ${sample_name}.fastq_r1_list.txt
        echo "${fastq_r2_string}" | tr ";" "\n" > ${sample_name}.fastq_r2_list.txt
    }

    output {
        Array[File] fastq_list_files = glob("*_list.txt")
    }

    runtime {
        memory: "8G"
        cpu: 1
        disks: "local-disk 500 SSD"
        docker: "debian"
    }
}

task FastqToSam {

    Array[File] fastq_list_files

    Array[File] fastq_r1_list = read_lines(fastq_list_files[0])
    Array[File]? fastq_r2_list = read_lines(fastq_list_files[1])

    Boolean single_end_argument
    String sample_name

    Array[File]+ hisat_index
    String hisat_prefix

    String? strandness
    String strandness_arg = if defined(strandness) then "--rna-strandness " + strandness + " " else ""

    command {
        if [[ "${single_end_argument}" == true ]]
            then
                echo "The single end input is detected"
                files=$(echo "-U "${sep="," fastq_r1_list})
            else
                echo "The paired end input is detected"
                files=$(echo "-1 "${sep="," fastq_r1_list}" -2 "${sep="," fastq_r2_list})
        fi

        echo the input file paths: $files

        /usr/local/bin/hisat2 -p 2 --dta -x ${hisat_prefix} ${strandness_arg} $files -S ${sample_name}.initially_mapped.sam
    }

    output {
        File initially_mapped_sam = glob("*.initially_mapped.sam")[0]
    }

    runtime {
        memory: "13G"
        cpu: 2
        disks: "local-disk 500 SSD"
        docker: "zlskidmore/hisat2:latest"
    }
}

task SamToCoordinateSortedBam {
    File input_sam
    String sample_name

    command {
        /usr/local/bin/samtools sort -@ 2 -l 9 -o ${sample_name}.coordinate_sorted.bam ${input_sam}
    }

    output {
        File coordinate_sorted_bam = "${sample_name}.coordinate_sorted.bam"
    }

    runtime {
        memory: "13G"
        cpu: 2
        disks: "local-disk 500 SSD"
        docker: "zlskidmore/samtools:latest"
    }
}

task PicardMarkDuplicates {
    String sample_name
    File input_bam

    command {
        java -Xmx8g -jar /usr/picard/picard.jar MarkDuplicates I=${input_bam} O=${sample_name}.duplicates_removed.bam ASSUME_SORT_ORDER=coordinate METRICS_FILE=${sample_name}.duplicates_metrics.txt QUIET=true COMPRESSION_LEVEL=9 VALIDATION_STRINGENCY=LENIENT REMOVE_DUPLICATES=true
    }

    output {
        File duplicates_removed_bam = "${sample_name}.duplicates_removed.bam"
        File duplicates_metrics_txt = "${sample_name}.duplicates_metrics.txt"
    }

    runtime {
        docker: "broadinstitute/picard:latest"
        disks: "local-disk 500 SSD"
        memory: "16G"
        cpu: 2
    }
}

task BamToQuerynameSortedBam{
    File input_bam
    String sample_name

    command {
        /usr/local/bin/samtools sort -@ 2 -l 9 -n -o ${sample_name}.queryname_sorted.bam ${input_bam}
    }

    output {
        File queryname_sorted_bam = "${sample_name}.queryname_sorted.bam"
    }

    runtime {
        memory: "13G"
        cpu: 2
        disks: "local-disk 500 SSD"
        docker: "zlskidmore/samtools:latest"
    }
}

task CallHtseqCount {
    # Only handle queryname sorted bam as input!
    String sample_name
    File input_bam
    File gtf_annotation

    # The HTSeq-count needs to know whether the reads are stranded or stranded.
    String? strandness
    String strandness_arg = if defined(strandness) then "--stranded=yes" else "--stranded=no"

    command {
        # htseq-count [options] <alignment_files> <gff_file>
        # https://htseq.readthedocs.io/en/release_0.11.1/count.html
        /usr/local/bin/htseq-count --format=bam ${strandness_arg} ${input_bam} ${gtf_annotation} > ${sample_name}.htseq_count.txt
    }

    output {
        File htseq_count_txt = "${sample_name}.htseq_count.txt"
    }

    runtime {
        # docker: "biocontainers/htseq:v0.11.2-1-deb-py3_cv1"
        docker: "quay.io/biocontainers/htseq:0.11.2--py36h7eb728f_0"
        memory: "13G"
        cpu: 2
        disks: "local-disk 500 SSD"
    }
}

task CompressResults {
    String sample_name
    File htseq_count_txt

    # -c --stdout      Compress or decompress to standard output.
    command {
        # gzip -9 -cvf ${htseq_count_txt} > ${sample_name}.htseq_count.txt.gz
        bzip2 -9 -cvf ${htseq_count_txt} > ${sample_name}.htseq_count.txt.bz2
    }

    output {
        # File htseq_count_compressed_file = "${sample_name}.htseq_count.txt.gz"
        File htseq_count_compressed_file = "${sample_name}.htseq_count.txt.bz2"
    }

    runtime {
        memory: "8G"
        cpu: 1
        disks: "local-disk 500 SSD"
        docker: "cmd.cat/bzip2"
    }
}


task CollectResultFiles {
    File sorted_bam
    File duplicates_metrics_txt
    File htseq_count_compressed_file

    String sorted_bam_result_directory
    String htseq_count_result_directory
    String duplicates_metrics_result_directory

    command {
        gsutil cp ${sorted_bam} ${sorted_bam_result_directory}
        gsutil cp ${htseq_count_compressed_file} ${htseq_count_result_directory}
        gsutil cp ${duplicates_metrics_txt} ${duplicates_metrics_result_directory}
    }

    runtime {
        docker: "google/cloud-sdk:latest"
        memory: "8G"
        cpu: 1
        disks: "local-disk 500 SSD"
    }

}
