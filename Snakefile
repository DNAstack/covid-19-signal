# To run the pipeline, do:
#
#    snakemake -kp --cores=NCORES --use-conda --conda-prefix=$HOME/.snakemake all
#    snakemake -p --cores=1 postprocess
#
# Note that the pipeline postprocessing ('snakemake postprocess') is separated from
# the rest of the pipeline ('snakemake all').  This is because in a multi-sample run,
# it's likely that at least one pipeline stage will fail.  The postprocessing script
# should handle failed pipeline stages gracefully, by substituting placeholder values
# when expected pipeline output files are absent.  However, this confuses snakemake's
# dependency tracking, so there seems to be no good alternative to separating piepline
# processing and postprocessing into 'all' and 'postprocess' targets.
#
# Related: because pipeline stages can fail, we recommend running 'snakemake all'
# with the -k flag ("Go on with independent jobs if a job fails").


####################################################################################################

from snakemake.utils import validate
import pandas as pd
import os

# The config file contains a high-level summary of pipeline configuration and inputs.
# It is ingested by the Snakefile, and also intended to be human-readable.
# For an example config file, see pipeline/example_config.yaml in the covid-19-sequencing repo.

# read and validate config.yaml
configfile: "config.yaml"
validate(config, 'resources/config.schema.yaml')

# read and validate sample table specified in config.schema.yaml
samples = pd.read_table(config['samples'], sep=',')
validate(samples, 'resources/sample.schema.yaml')

# get sample names 
sample_names = sorted(samples['sample'].drop_duplicates().values)

def get_input_fastq_files(sample_name, r):
    sample_fastqs = samples[samples['sample'] == sample_name]
    if r == '1':
        relpaths = sample_fastqs['r1_path'].values
    elif r == '2':
        relpaths = sample_fastqs['r2_path'].values

    return [ os.path.abspath(r) for r in relpaths ]


######################################   High-level targets   ######################################

rule sort:
    input: expand('{sn}/combined_raw_fastq/R{r}_fastqc.html', sn=sample_names, r=[1,2])

rule remove_adapters:
    input: expand('{sn}/adapter_trimmed/R{r}_val_{r}.fq.gz', sn=sample_names, r=[1,2])

rule host_removed_raw_reads:
    input: expand('{sn}/host_removal/R{r}.fastq.gz', sn=sample_names, r=[1,2]),

rule fastqc:
    input: expand('{sn}/adapter_trimmed/R{r}_val_{r}_fastqc.html', sn=sample_names, r=[1,2]),
           expand('{sn}/mapped_clean_reads/R{r}_fastqc.html', sn=sample_names, r=[1,2])

rule clean_reads:
    input:
       expand("{sn}/core/reference.mapped.primertrimmed.bam", sn=sample_names),
       expand('{sn}/mapped_clean_reads/R{r}.fastq.gz', sn=sample_names, r=[1,2])

rule consensus:
    input: expand('{sn}/core/virus.consensus.fa', sn=sample_names)

rule ivar_variants:
    input: expand('{sn}/core/ivar_variants.tsv', sn=sample_names)

rule breseq:
    input: expand('{sn}/breseq/output/index.html', sn=sample_names)
    
rule coverage:
    input: expand('{sn}/coverage/depth.txt', sn=sample_names)

rule kraken2:
    input: expand('{sn}/kraken2/kraken2.out', sn=sample_names)

rule quast:
    input: expand('{sn}/quast/report.html', sn=sample_names)


rule all:
    input:
        rules.sort.input,
        rules.host_removed_raw_reads.input,
        rules.remove_adapters.input,
        rules.fastqc.input,
        rules.clean_reads.input,
        rules.consensus.input,
        rules.ivar_variants.input,
        rules.breseq.input,
        rules.coverage.input,
        rules.kraken2.input,
        rules.quast.input


rule postprocess:
    conda: 
        'conda_envs/postprocessing.yaml'
    params:
        sample_csv_filename = config['samples']
    shell:
        'scripts/c19_postprocess.py {params.sample_csv_filename}'


rule ncov_tools:
    conda:
        'conda_envs/ncov-tools.yaml'
    #output:
    #    qc_analysis
    input:
        consensus = expand('{sn}/core/virus.consensus.fa', sn=sample_names),
        bams = expand("{sn}/core/reference.mapped.primertrimmed.sorted.bam", sn=sample_names)
    script: "scripts/ncov-tools.py"
        
        


#################################   Based on scripts/assemble.sh   #################################
rule concat_and_sort:
    priority: 4
    output:
        '{sn}/combined_raw_fastq/R{r}.fastq.gz'
    input:
        lambda wildcards: get_input_fastq_files(wildcards.sn, wildcards.r)
    benchmark:
        "{sn}/benchmarks/concat_and_sort_R{r}.benchmark.tsv"
    shell:
        'zcat -f {input} | paste - - - - | sort -k1,1 -t " " | tr "\\t" "\\n" | gzip > {output}'

rule run_raw_fastqc:
    conda: 
        'conda_envs/trim_qc.yaml'
    output:
        r1_fastqc = '{sn}/combined_raw_fastq/R1_fastqc.html',
        r2_fastqc = '{sn}/combined_raw_fastq/R2_fastqc.html'
    input:
        r1 = '{sn}/combined_raw_fastq/R1.fastq.gz',
        r2 = '{sn}/combined_raw_fastq/R2.fastq.gz'
    benchmark:
        '{sn}/benchmarks/raw_fastqc.benchmark.tsv'
    params:
        output_prefix = '{sn}/combined_raw_fastq'
    log:
        '{sn}/combined_raw_fastq/fastqc.log'
    shell:
        """
        fastqc -o {params.output_prefix} {input} 2> {log}
        """

########################## Human Host Removal ################################
rule raw_reads_human_reference_bwa_map:
    threads: 2
    conda: 
        'conda_envs/snp_mapping.yaml'
    output:
        '{sn}/host_removal/human_mapping_reads.bam'
    input:
        raw_r1 = '{sn}/combined_raw_fastq/R1.fastq.gz',
        raw_r2 = '{sn}/combined_raw_fastq/R2.fastq.gz'
    benchmark:
        "{sn}/benchmarks/human_reference_bwa_map.benchmark.tsv"
    log:
        '{sn}/host_removal/human_read_mapping.log'
    params:
       human_index = os.path.abspath(config['human_reference'])
    shell:
        '(bwa mem -T 30 -t {threads} {params.human_index} '
        '{input.raw_r1} {input.raw_r2} | '
        'samtools view -bS | samtools sort -n -@{threads} -o {output}) 2> {log}'

rule get_host_removed_reads:
    conda: 'conda_envs/snp_mapping.yaml'
    output:
        r1 = '{sn}/host_removal/R1.fastq',
        r2 = '{sn}/host_removal/R2.fastq',
        bam = '{sn}/host_removal/human_mapping_reads_filtered_sorted.bam'
    input:
        '{sn}/host_removal/human_mapping_reads.bam'
    benchmark:
        "{sn}/benchmarks/get_host_removed_reads.benchmark.tsv"
    log:
        '{sn}/host_removal/bamtofastq.log'
    shell:
        """
        samtools view -b -f4 {input} | samtools sort -n > {output.bam} 2> {log}
        bedtools bamtofastq -i {output.bam} -fq {output.r1} -fq2 {output.r2} 2>> {log} 
        """

rule gzip_host_removed_reads:
    output:
        '{sn}/host_removal/R1.fastq.gz',
        '{sn}/host_removal/R2.fastq.gz',
    input:
        '{sn}/host_removal/R1.fastq',
        '{sn}/host_removal/R2.fastq',
    shell:
        """
        gzip {input}
        """

###### Based on github.com/connor-lab/ncov2019-artic-nf/blob/master/modules/illumina.nf#L124 ######

rule run_trimgalore:
    threads: 2
    priority: 2
    conda: 
        'conda_envs/trim_qc.yaml'
    output:
        '{sn}/adapter_trimmed/R1_val_1.fq.gz',
        '{sn}/adapter_trimmed/R2_val_2.fq.gz',
        '{sn}/adapter_trimmed/R1_val_1_fastqc.html',
        '{sn}/adapter_trimmed/R2_val_2_fastqc.html'
    input:
        raw_r1 = '{sn}/host_removal/R1.fastq.gz',
        raw_r2 = '{sn}/host_removal/R2.fastq.gz'
    log:
        '{sn}/adapter_trimmed/trim_galore.log'
    benchmark:
        "{sn}/benchmarks/trimgalore.benchmark.tsv"
    params:
        min_len = config['min_len'],
        min_qual = config['min_qual'],
        output_prefix = '{sn}/adapter_trimmed'
    shell:
        'trim_galore --quality {params.min_qual} --length {params.min_len} '
        ' -o {params.output_prefix} --cores {threads} --fastqc '
        '--paired {input.raw_r1} {input.raw_r2} 2> {log}'

rule reference_bwa_build:
    conda: 
        'conda_envs/snp_mapping.yaml'
    output:
        '{sn}/core/reference.bwt'
    input:
        reference = config['viral_reference_genome'],
    log:
        '{sn}/core/bwa-build.log'
    benchmark:
        "{sn}/benchmarks/reference_bwa_build.benchmark.tsv"
    params:
        output_prefix = "{sn}/core/reference"
    shell:
        'bwa index -p {params.output_prefix} {input} >{log} 2>&1'


rule reference_bwa_map:
    threads: 2
    conda: 
        'conda_envs/snp_mapping.yaml'
    output:
        '{sn}/core/reference.bam'
    input:
        r1  = '{sn}/adapter_trimmed/R1_val_1.fq.gz',
        r2  = '{sn}/adapter_trimmed/R2_val_2.fq.gz',
        ref = '{sn}/core/reference.bwt'
    benchmark:
        "{sn}/benchmarks/reference_bwa_map.benchmark.tsv"
    log:
        '{sn}/core/bwa.log'
    params:
       ref_prefix = '{sn}/core/reference'
    shell:
        '(bwa mem -t {threads} {params.ref_prefix} '
        '{input.r1} {input.r2} | '
        'samtools view -bS | samtools sort -@{threads} -o {output}) 2> {log}'

rule run_bed_primer_trim:
    conda: 
        'conda_envs/ivar.yaml'
    input:
        "{sn}/core/reference.bam"
    output:
        sorted_trimmed_mapped_bam = "{sn}/core/reference.mapped.primertrimmed.sorted.bam",
        trimmed_mapped_bam = "{sn}/core/reference.mapped.primertrimmed.bam",
        mapped_bam = "{sn}/core/reference.mapped.bam"
    benchmark:
        "{sn}/benchmarks/bed_primer_trim.benchmark.tsv"
    log:
        "{sn}/core/ivar_trim.log"
    params:
        scheme_bed = os.path.abspath(config['scheme_bed']),
        ivar_output_prefix = "{sn}/core/reference.mapped.primertrimmed",
        min_len = config['min_len'],
        min_qual = config['min_qual'],
    shell:
        'samtools view -F4 -o {output.mapped_bam} {input}; '
        'samtools index {output.mapped_bam}; '
        'ivar trim -e -i {output.mapped_bam} -b {params.scheme_bed} '
        '-m {params.min_len} -q {params.min_qual} '
        '-p {params.ivar_output_prefix} 2> {log}; '
        'samtools sort -o {output.sorted_trimmed_mapped_bam} '
        '{output.trimmed_mapped_bam}'

rule run_fastqc_on_mapped_reads:
    conda: 'conda_envs/trim_qc.yaml'
    output:
        r1_fastqc = '{sn}/mapped_clean_reads/R1_fastqc.html',
        r2_fastqc = '{sn}/mapped_clean_reads/R2_fastqc.html'
    input:
        r1 = '{sn}/mapped_clean_reads/R1.fastq.gz',
        r2 = '{sn}/mapped_clean_reads/R2.fastq.gz'
    benchmark:
        '{sn}/benchmarks/clean_fastqc.benchmark.tsv'
    params:
        output_prefix = '{sn}/mapped_clean_reads'
    log:
        '{sn}/mapped_clean_reads/fastqc.log'
    shell:
        """
        fastqc -o {params.output_prefix} {input} 2> {log}
        """

rule get_mapping_reads:
    priority: 2
    conda: 'conda_envs/snp_mapping.yaml'
    output:
        r1 = '{sn}/mapped_clean_reads/R1.fastq',
        r2 = '{sn}/mapped_clean_reads/R2.fastq',
        bam = '{sn}/mapped_clean_reads/sorted_clean.bam'
    input:
        "{sn}/core/reference.mapped.primertrimmed.bam",
    benchmark:
        "{sn}/benchmarks/get_mapping_reads.benchmark.tsv"
    log:
        '{sn}/mapped_clean_reads/bamtofastq.log'
    shell:
        """
        samtools sort -n {input} -o {output.bam} 2> {log}
        bedtools bamtofastq -i {output.bam} -fq {output.r1} -fq2 {output.r2} 2>> {log} 
        """

rule clean_reads_gzip:
    priority: 2
    output:
        '{sn}/mapped_clean_reads/R{r}.fastq.gz'
    input:
        '{sn}/mapped_clean_reads/R{r}.fastq'
    benchmark:
        "{sn}/benchmarks/clean_reads_gzip_{r}.benchmark.tsv"
    shell:
        'gzip {input}'


rule run_ivar_consensus:
    conda: 
        'conda_envs/ivar.yaml'
    output:
        '{sn}/core/virus.consensus.fa'
    input:
        "{sn}/core/reference.mapped.primertrimmed.sorted.bam"
    log:
        '{sn}/core/ivar_consensus.log'
    benchmark:
        "{sn}/benchmarks/ivar_consensus.benchmark.tsv"
    params:
        mpileup_depth = config['mpileup_depth'],
        ivar_min_coverage_depth = config['ivar_min_coverage_depth'],
        ivar_freq_threshold = config['ivar_freq_threshold'],
        output_prefix = '{sn}/core/virus.consensus'
    shell:
        '(samtools mpileup -A -d {params.mpileup_depth} -Q0 {input} | '
        'ivar consensus -t {params.ivar_freq_threshold} '
        '-m {params.ivar_min_coverage_depth} -n N -p {params.output_prefix}) '
        '2>{log}'

rule run_ivar_variants:
    conda: 
        'conda_envs/ivar.yaml'
    output:
        '{sn}/core/ivar_variants.tsv'
    input:
        reference = config['viral_reference_genome'],
        read_bam = "{sn}/core/reference.mapped.primertrimmed.sorted.bam"
    log:
        '{sn}/core/ivar_variants.log'
    benchmark:
        "{sn}/benchmarks/ivar_variants.benchmark.tsv"
    params:
        output_prefix = '{sn}/core/ivar_variants',
        ivar_min_coverage_depth = config['ivar_min_coverage_depth'],
        ivar_min_freq_threshold = config['ivar_min_freq_threshold'],
        ivar_min_variant_quality = config['ivar_min_variant_quality']
    shell:
        '(samtools mpileup -A -d 0 --reference {input.reference} -B '
            '-Q 0 {input.read_bam} | '
        'ivar variants -r {input.reference} -m {params.ivar_min_coverage_depth} '
        '-p {params.output_prefix} -q {params.ivar_min_variant_quality} '
        '-t {params.ivar_min_freq_threshold}) 2> {log}'


################################   Based on scripts/breseq.sh   ####################################

rule run_breseq:
    threads: 4
    priority: 1
    conda: 'conda_envs/snp_mapping.yaml'
    output:
        '{sn}/breseq/output/index.html'
    input:
        expand('{{sn}}/mapped_clean_reads/R{r}.fastq.gz', r=[1,2])
    log:
        '{sn}/breseq/breseq.log',
    benchmark:
        "{sn}/benchmarks/run_breseq.benchmark.tsv"
    params:
        ref = config['breseq_reference'],
	outdir = '{sn}/breseq'
    shell:
        'breseq --reference {params.ref} --num-processors {threads} --polymorphism-prediction --brief-html-output --output {params.outdir} {input} >{log} 2>&1'


##################  Based on scripts/hisat2.sh and scripts/coverage_stats_avg.sh  ##################


rule coverage_depth:
    conda: 'conda_envs/snp_mapping.yaml'
    output:
        '{sn}/coverage/depth.txt'
    input:
        "{sn}/core/reference.mapped.primertrimmed.sorted.bam"
    benchmark:
        "{sn}/benchmarks/coverage_depth.benchmark.tsv"
    shell:
        'bedtools genomecov -d -ibam {input} >{output}'


################################   Based on scripts/kraken2.sh   ###################################


rule run_kraken2:
    threads: 1
    conda: 'conda_envs/trim_qc.yaml'
    output:
        '{sn}/kraken2/kraken2.out'
    input:
        expand('{{sn}}/adapter_trimmed/R{r}_val_{r}.fq.gz', r=[1,2])
    log:
        '{sn}/kraken2/kraken2.log'
    benchmark:
        "{sn}/benchmarks/run_kraken2.benchmark.tsv"
    params:
        outdir = '{sn}/kraken2',
	    db = os.path.abspath(config['kraken2_db'])
    shell:
        'cd {params.outdir} '
	'&& kraken2'
	' --db {params.db}'
	' --threads {threads}'
	' --quick --unclassified-out unclassified-sequences# --classified-out classified-sequences#'
	' --output kraken2.out'
	' --paired --gzip-compressed'
	' ../../{input[0]} ../../{input[1]}'
	' --report report'
        ' 2>../../{log}'

##################################  Based on scripts/quast.sh   ####################################


rule run_quast:
    threads: 1
    conda: 'conda_envs/assembly_qc.yaml'
    output:
         '{sn}/quast/report.html'
    input:
         '{sn}/core/virus.consensus.fa'
    log:
         '{sn}/quast/quast.log'
    benchmark:
        "{sn}/benchmarks/run_quast.benchmark.tsv"
    params:
         outdir = '{sn}/quast',
         genome = config['viral_reference_genome'],
         fcoords = config['viral_reference_feature_coords']
    shell:
         'quast {input} -r {params.genome} -g {params.fcoords} --output-dir {params.outdir} --threads {threads} >{log}'
