path_to_fauna = '../fauna/data'
segments = ['ha', 'na']
lineages = ['h3n2']
resolutions = ['2y']
frequency_regions = ['north_america', 'south_america', 'europe', 'china',
                     'southeast_asia', 'japan_korea', 'south_asia', 'africa']


def reference_strain(v):
    references = {'h3n2':"A/Beijing/32/1992",
                  'h1n1pdm':"A/California/07/2009",
                  'vic':"B/HongKong/02/1993",
                  'yam':"B/Singapore/11/1994"
                  }
    return references[v.lineage]

def titer_data(w):
    titers = {'h1n1':path_to_fauna + '/h1n1_cdc_hi_cell_titers.tsv',
            'h3n2':path_to_fauna + '/h3n2_cdc_hi_cell_titers.tsv',
            'yam':path_to_fauna + '/yam_cdc_hi_cell_titers.tsv',
            'vic':path_to_fauna + '/vic_cdc_hi_cell_titers.tsv',
            'Ball':path_to_fauna + '/Ball_cdc_hi_cell_titers.tsv',
            'h1n1pdm':path_to_fauna + '/h1n1pdm_cdc_hi_cell_titers.tsv'}
    return titers[w.lineage]

def gene_names(w):
    genes_to_translate = {'ha':['HA1', 'HA2'], 'na':['NA']}
    return genes_to_translate[w.segment]

def translations(w):
    genes = gene_names(w)
    return ["results/aaseq-seasonal-%s_%s_%s_%s.fasta"%(g, w.lineage, w.segment, w.resolution)
            for g in genes]

def region_translations(w):
    genes = gene_names(w)
    return ["results/full-aaseq-seasonal-%s_%s_%s_%s_%s.fasta"%(g, w.region, w.lineage, w.segment, w.resolution)
            for g in genes]

def pivots_per_year(w):
    pivots_per_year = {'2y':12, '3y':6, '6y':4, '12y':2}
    return pivots_per_year[w.resolution]

def min_date(w):
    from datetime import date
    from treetime.utils import numeric_date
    now = numeric_date(date.today())
    return now - int(w.resolution[:-1])

def substitution_rates(w):
    references = {('h3n2', 'ha'): 0.0038, ('h3n2', 'na'):0.0028,
                  }
    return references[(w.lineage, w.segment)]

def mutations_to_plot(v):
    mutations = {'h3n2':["HA1:135K", "HA1:131T"]
                  }
    return mutations[v.lineage]


def vpm(v):
    vpm = {'3y':2, '6y':2, '12y':1}
    return vpm[v.resolution] if v.resolution in vpm else 5


rule all:
    input:
        auspice_tree = expand("auspice/flu_seasonal_{lineage}_{segment}_{resolution}_tree.json", lineage=lineages, segment=segments, resolution=resolutions),
        auspice_meta = expand("auspice/flu_seasonal_{lineage}_{segment}_{resolution}_meta.json", lineage=lineages, segment=segments, resolution=resolutions)


rule frequency_graphs:
    input:
        mutations = expand("results/mutation_frequencies_{region}_{{lineage}}_{{segment}}_{{resolution}}.json",
                    region=['north_america', 'europe', 'china']),
        tree = "results/tree_frequencies_{lineage}_{segment}_{resolution}.json"
    params:
        mutations = mutations_to_plot,
        regions = ['north_america', 'europe', 'china']
    output:
        mutations = "figures/mutation_frequencies_{lineage}_{segment}_{resolution}.png",
        counts = "figures/sample-count_{lineage}_{segment}_{resolution}.png"
    shell:
        """
        python scripts/graph_frequencies.py --mutation-frequencies {input.mutations} \
                                            --tree-frequencies {input.tree} \
                                            --mutations {params.mutations} \
                                            --regions {params.regions} \
                                            --output-mutations {output.mutations} \
                                            --output-counts {output.counts}
        """



rule files:
    params:
        input_fasta = path_to_fauna+"/{lineage}_{segment}.fasta",
        outliers = "config/outliers_{lineage}.txt",
        references = "config/references_{lineage}.txt",
        reference = "config/{lineage}_{segment}_outgroup.gb",
        colors = "config/colors.tsv",
        auspice_config = "config/auspice_config.json",

files = rules.files.params


rule parse:
    message: "Parsing fasta into sequences and metadata"
    input:
        sequences = files.input_fasta
    output:
        sequences = "results/sequences_{lineage}_{segment}.fasta",
        metadata = "results/metadata_{lineage}_{segment}.tsv"
    params:
        fasta_fields =  "strain virus isolate_id date region country division passage authors age gender"

    shell:
        """
        augur parse \
            --sequences {input.sequences} \
            --output-sequences {output.sequences} \
            --output-metadata {output.metadata} \
            --fields {params.fasta_fields}
        """


rule select_strains:
    input:
        metadata = lambda w:expand("results/metadata_{lineage}_{segment}.tsv", segment=segments, lineage=w.lineage)
    output:
        strains = "results/strains_seasonal_{lineage}_{resolution}.txt",
    params:
        viruses_per_month = vpm,
        exclude = files.outliers,
        include = files.references,
        titers = titer_data
    shell:
        """
        python scripts/select_strains.py --metadata {input.metadata} \
                                  --segments {segments} \
                                  --exclude {params.exclude} --include {params.include} \
                                  --resolution {wildcards.resolution} --lineage {wildcards.lineage} \
                                  --viruses_per_month {params.viruses_per_month} \
                                  --titers {params.titers} \
                                  --output {output.strains}
        """

rule filter:
    input:
        metadata = rules.parse.output.metadata,
        sequences = 'results/sequences_{lineage}_{segment}.fasta',
        strains = rules.select_strains.output.strains
    output:
        sequences = 'results/sequences_seasonal_{lineage}_{segment}_{resolution}.fasta'
    run:
        from Bio import SeqIO
        with open(input.strains) as infile:
            strains = set(map(lambda x:x.strip(), infile.readlines()))
        with open(output.sequences, 'w') as outfile:
            for seq in SeqIO.parse(input.sequences, 'fasta'):
                if seq.name in strains:
                    SeqIO.write(seq, outfile, 'fasta')


rule full_region_alignments:
    input:
        metadata = rules.parse.output.metadata,
        sequences = 'results/sequences_{lineage}_{segment}.fasta',
        exclude = files.outliers,
        reference = "config/{lineage}_{segment}_outgroup.gb"
    params:
        genes = gene_names,
        aa_alignment = "results/full-aaseq-seasonal-%GENE_%REGION_{lineage}_{segment}_{resolution}.fasta"
    output:
        alignments = expand("results/full-aaseq-seasonal-{{gene}}_{region}_{{lineage}}_{{segment}}_{{resolution}}.fasta", region=frequency_regions)
    shell:
        """
        python scripts/full_region_alignments.py  --sequences {input.sequences}\
                                             --metadata {input.metadata} \
                                             --exclude {input.exclude} \
                                             --genes {params.genes} \
                                             --reference {input.reference} \
                                             --output {params.aa_alignment}
        """


rule align:
    message:
        """
        Aligning sequences to {input.reference}
          - filling gaps with N
        """
    input:
        sequences = rules.filter.output.sequences,
        reference = files.reference
    output:
        alignment = "results/aligned_seasonal_{lineage}_{segment}_{resolution}.fasta"
    shell:
        """
        augur align \
            --sequences {input.sequences} \
            --reference-sequence {input.reference} \
            --output {output.alignment} \
            --fill-gaps
        """

rule tree:
    message: "Building tree"
    input:
        alignment = rules.align.output.alignment
    output:
        tree = "results/treeraw_seasonal_{lineage}_{segment}_{resolution}.nwk"
    shell:
        """
        augur tree \
            --alignment {input.alignment} \
            --output {output.tree}
        """

rule refine:
    message:
        """
        Refining tree
          - estimate timetree
          - use {params.coalescent} coalescent timescale
          - estimate {params.date_inference} node dates
          - filter tips more than {params.clock_filter_iqd} IQDs from clock expectation
        """
    input:
        tree = rules.tree.output.tree,
        alignment = rules.align.output,
        metadata = rules.parse.output.metadata
    output:
        tree = "results/tree_seasonal_{lineage}_{segment}_{resolution}.nwk",
        node_data = "results/branchlengths_seasonal_{lineage}_{segment}_{resolution}.json"
    params:
        coalescent = "const",
        date_inference = "marginal",
        clock_filter_iqd = 4
    shell:
        """
        augur refine \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --metadata {input.metadata} \
            --output-tree {output.tree} \
            --output-node-data {output.node_data} \
            --timetree \
            --coalescent {params.coalescent} \
            --date-confidence \
            --date-inference {params.date_inference} \
            --clock-filter-iqd {params.clock_filter_iqd}
        """

rule ancestral:
    message: "Reconstructing ancestral sequences and mutations"
    input:
        tree = rules.refine.output.tree,
        alignment = rules.align.output
    output:
        node_data = "results/ntmuts_seasonal_{lineage}_{segment}_{resolution}.json"
    params:
        inference = "joint"
    shell:
        """
        augur ancestral \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --output {output.node_data} \
            --inference {params.inference}
        """

rule translate:
    message: "Translating amino acid sequences"
    input:
        tree = rules.refine.output.tree,
        node_data = rules.ancestral.output.node_data,
        reference = files.reference
    output:
        node_data = "results/aamuts_seasonal_{lineage}_{segment}_{resolution}.json",
    shell:
        """
        augur translate \
            --tree {input.tree} \
            --ancestral-sequences {input.node_data} \
            --reference-sequence {input.reference} \
            --output {output.node_data} \
        """

rule reconstruct_translations:
    message: "Reconstructing translations required for titer models and frequencies"
    input:
        tree = rules.refine.output.tree,
        node_data = "results/aamuts_seasonal_{lineage}_{segment}_{resolution}.json",
    params:
        genes = gene_names,
        aa_alignment = "results/aaseq-seasonal-%GENE_{lineage}_{segment}_{resolution}.fasta"
    output:
        aa_alignment = "results/aaseq-seasonal-{gene}_{lineage}_{segment}_{resolution}.fasta"
    shell:
        """
        augur reconstruct-sequences \
            --tree {input.tree} \
            --mutations {input.node_data} \
            --genes {params.genes} \
            --output {params.aa_alignment}
        """


rule titers:
    input:
        tree = rules.refine.output.tree,
        titers = titer_data,
        aa_muts = rules.translate.output,
        alignments = translations
    params:
        genes = gene_names
    output:
        tree_model = "results/HITreeModel_seasonal_{lineage}_{segment}_{resolution}.json",
        subs_model = "results/HISubsModel_seasonal_{lineage}_{segment}_{resolution}.json",
    shell:
        """
        augur titers --tree {input.tree}\
            --titers {input.titers}\
            --titer-model tree \
            --output {output.tree_model} &
        augur titers --tree {input.tree}\
            --titers {input.titers}\
            --titer-model substitution \
            --alignment {input.alignments} \
            --gene-names {params.genes} \
            --output {output.subs_model}
        """

rule mutation_frequencies:
    input:
        metadata = rules.parse.output.metadata,
        alignment = translations
    params:
        genes = gene_names,
        pivots_per_year = pivots_per_year
    output:
        mut_freq = "results/mutation_frequencies_{lineage}_{segment}_{resolution}.json"
    shell:
        """
        augur frequencies --alignments {input.alignment} \
                          --metadata {input.metadata} \
                          --gene-names {params.genes} \
                          --pivots-per-year {params.pivots_per_year} \
                          --output {output.mut_freq}
        """

rule complete_mutation_frequencies:
    input:
        metadata = rules.parse.output.metadata,
        alignment = region_translations
    params:
        genes = gene_names,
        pivots_per_year = pivots_per_year
    output:
        mut_freq = "results/mutation_frequencies_{region}_{lineage}_{segment}_{resolution}.json"
    shell:
        """
        augur frequencies --alignments {input.alignment} \
                          --metadata {input.metadata} \
                          --gene-names {params.genes} \
                          --pivots-per-year {params.pivots_per_year} \
                          --output {output.mut_freq}
        """


rule tree_frequencies:
    input:
        metadata = rules.parse.output.metadata,
        tree = rules.refine.output.tree
    params:
        regions = frequency_regions + ['global'],
        min_date = min_date,
        pivots_per_year = pivots_per_year
    output:
        tree_freq = "results/tree_frequencies_{lineage}_{segment}_{resolution}.json",
    shell:
        """
        augur frequencies --tree {input.tree} \
                          --metadata {input.metadata} \
                          --pivots-per-year {params.pivots_per_year} \
                          --regions {params.regions} \
                          --min-date {params.min_date} \
                          --output {output.tree_freq}
        """

rule export:
    input:
        tree = rules.refine.output.tree,
        node_data = rules.refine.output.node_data,
        metadata = rules.parse.output.metadata,
        nt_muts = rules.ancestral.output,
        aa_muts = rules.translate.output,
        tree_model = rules.titers.output.tree_model,
        auspice_config = files.auspice_config
    output:
        auspice_tree = "auspice/flu_seasonal_{lineage}_{segment}_{resolution}_tree.json",
        auspice_meta = "auspice/flu_seasonal_{lineage}_{segment}_{resolution}_meta.json"
    shell:
        """
        augur export \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --node-data {input.node_data} {input.nt_muts} {input.aa_muts} {input.tree_model}\
            --auspice-config {input.auspice_config} \
            --output-tree {output.auspice_tree} \
            --output-meta {output.auspice_meta}
        """
