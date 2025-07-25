=head1 LICENSE

See the NOTICE file distributed with this work for additional information
regarding copyright ownership.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::ncRNAtrees::PrepareSecStructModels

=head1 SYNOPSIS

my $db           = Bio::EnsEMBL::Compara::DBAdaptor->new($locator);
my $ncsecstructtree = Bio::EnsEMBL::Compara::RunnableDB::ncRNAtrees::PrepareSecModels->new
  (
   -db         => $db,
   -input_id   => $input_id,
   -analysis   => $analysis
  );
$ncsecstructtree->fetch_input(); #reads from DB
$ncsecstructtree->run();
$ncsecstructtree->write_output(); #writes to DB

=head1 DESCRIPTION

This RunnableDB builds phylogenetic trees using RAxML. RAxML can use several secondary
structure substitution models. This Runnable can run several of them in a row, but it
is recommended to run them in parallel.

=cut


package Bio::EnsEMBL::Compara::RunnableDB::ncRNAtrees::PrepareSecStructModels;

use strict;
use warnings;
use Time::HiRes qw(time);
use Bio::EnsEMBL::Compara::Graph::NewickParser;

use base ('Bio::EnsEMBL::Compara::RunnableDB::ncRNAtrees::NCStoreTree');

sub param_defaults {
    return {
        'models'      => [qw/S16B S16A S7B S7C S6A S6B S6C S6D S6E S7A S7D S7E S7F S16/],
    };
}

=head2 fetch_input

    Title   :   fetch_input
    Usage   :   $self->fetch_input
    Function:   Fetches input data from the database
    Returns :   none
    Args    :   none

=cut

sub fetch_input {
    my $self = shift @_;

    my $nc_tree_id = $self->param_required('gene_tree_id');

    my $nc_tree = $self->compara_dba->get_GeneTreeAdaptor->fetch_by_dbID($nc_tree_id) or $self->throw("Could not fetch nc_tree with id=$nc_tree_id");
    $self->param('gene_tree', $nc_tree);
    $self->_load_species_tree_string_from_db();

    my $alignment_id = $self->param_required('alignment_id');
    $nc_tree->gene_align_id($alignment_id);
    print STDERR "ALN INPUT ID: $alignment_id\n" if ($self->debug);
    my $aln = $self->compara_dba->get_GeneAlignAdaptor->fetch_by_dbID($alignment_id);
    print STDERR scalar (@{$nc_tree->get_all_Members}), "\n";
    $nc_tree->alignment($aln);

### !! Struct files are not used in this first tree!!
    # But calling _dumpStructToWorkdir helps detecting problematic ss_cons strings
    $self->cleanup_worker_temp_directory;
    $self->param('input_aln',  $self->_dumpMultipleAlignmentToWorkdir($nc_tree));
    $self->param('struct_aln', $self->_dumpStructToWorkdir($nc_tree));
}

=head2 run

    Title   :   run
    Usage   :   $self->run
    Function:   runs something
    Returns :   none
    Args    :   none

=cut

sub run {
    my $self = shift @_;
    my $nc_tree_id = $self->param('gene_tree_id');
    # First check the size of the alignents to compute:
#     if ($self->param('tag_residue_count') > 150000) {
#         $self->dataflow_output_id (
#                                    {
#                                     'gene_tree_id' => $nc_tree_id,
#                                     'alignment_id' => $self->param('alignment_id'),
#                                    }, -1
#                                   );
#         # We die here. Nothing more to do in the Runnable
#         $self->input_job->autoflow(0);
#         $self->complete_early("$nc_tree_id family is too big. Only fast trees will be computed\n");
#     } else {
    # Run RAxML without any structure info first
        $self->_run_bootstrap_raxml;
#    }
}

=head2 write_output

    Title   :   write_output
    Usage   :   $self->write_output
    Function:   stores something
    Returns :   none
    Args    :   none

=cut


sub write_output {
    my $self = shift @_;

    # Run RAxML with all selected secondary structure substitution models
    # $self->_run_ncsecstructtree;

    my $nc_tree_id = $self->param('gene_tree_id');
    my $models = $self->param('models');
    my $bootstrap_num = $self->param('bootstrap_num');
    print STDERR "Bootstrap_num: $bootstrap_num\n" if ($self->debug());

    for my $model (@$models) {
        $self->dataflow_output_id ( {
                                     'model' => $model,
                                     'gene_tree_id' => $nc_tree_id,
                                     'bootstrap_num' => $bootstrap_num,
                                     'alignment_id'  => $self->param('alignment_id'),
                                     'aln_length'  => $self->param('aln_length'),
                                    }, 2); # fan
    }

}

sub _run_bootstrap_raxml {
    my ($self, $no_bfgs) = @_;


    ## Regarding RAxML 7.2.8 (https://cme.h-its.org/exelixis/web/software/raxml/)
#In RAxML 7.0.4, a run specified with the model GTRGAMMA (command line = -m GTRGAMMA -x -f a) performed rapid bootstrapping using the GTRCAT model, followed by an ML search using the GTRGAMMA model. That is, GTRGAMMA was used only for the ML search, while GTRCAT was used during the bootstrapping for improved efficiency. Similarly, RAxML 7.0.4 offered the option GTRMIX conducted inference under GRTCAT and calculated best tree under GTRGAMMA. The GTRMIX option (which conducted inference under GRTCAT and calculated best tree under GTRGAMMA) is no longer offered for RAxML 7.1.0 and above.

#For RAxML 7.2.8, selecting the GTRGAMMA model has a very different effect (command line = -m GTRGAMMA -x -f a). This option causes GTRGAMMA to be used both during the rapid bootstrapping AND inference of the best tree. The result is that it takes much longer to produce results using GTRGAMMA in RAxML 7.0.4, and the analysis is different from the one run using RAxML 7.0.4, where GTRCAT was used to conduct the bootstrapping phase. If you wish to run the same analysis you ran using RAxML 7.0.4, you must instead choose the model GTRCAT (-m GTRCAT -x -f a)

    my $aln_file = $self->param('input_aln');
    return unless (defined($aln_file));

    my $raxml_tag = $self->param('gene_tree')->root_id . "." . $self->worker->process_id . ".raxml";
    my $cores = $self->param('raxml_number_of_cores');
    $self->raxml_exe_decision();
    my $raxml_exe = $self->require_executable('raxml_exe');

  # Unlink previous files
  my $temp_dir = $self->worker_temp_directory;
  my $temp_regexp = $temp_dir."*$raxml_tag.*";
  $self->run_command("rm -f $temp_regexp");

    my $bootstrap_num = 10;

  my $cmd = $raxml_exe;
  $cmd .= " -p 12345";
  $cmd .= " -T $cores"; # ATTN, you need the PTHREADS version of raxml for this
  $cmd .= " -m GTRGAMMA";
  $cmd .= " -s $aln_file";
  $cmd .= " -N $bootstrap_num";
  $cmd .= " -n $raxml_tag.$bootstrap_num";
  $cmd .= " --no-bfgs" if $no_bfgs;

  my $worker_temp_directory = $self->worker_temp_directory;
  print "$cmd\n" if($self->debug);
  my $bootstrap_starttime = time()*1000;


    # The idea here is to try first rerunning RAxML before trying it with a better capacity.
    # We have observed that in many cases RAxML would be running for 4 days, and if we restar the jobs it would finish in less than 1 hour.
    my $command = $self->run_command("cd $worker_temp_directory; $cmd", { timeout => $self->param('cmd_max_runtime') } );

    if ( $command->exit_code == -2 ) {

        #RAxML can be stuck ... restarting
        $self->warning( sprintf("Timeout reached, it is better to restart RAxML for 'PrepareSecStructModels'.\n") );
        if (defined( $self->param('more_cores_branch') )) {
            $command = $self->run_command( "cd $worker_temp_directory; rm RAxML_*; $cmd", { timeout => $self->param('cmd_max_runtime') } );
        } else {
            $command = $self->run_command( "cd $worker_temp_directory; rm RAxML_*; $cmd" );
        }

        if ( $command->exit_code == -2 ) {
            $self->input_job->autoflow(0);
            $self->dataflow_output_id( undef, $self->param('more_cores_branch') );
            my $n_hours = $self->param('cmd_max_runtime')/3600;
            $self->complete_early("Could no complete RAxML (PrepareSecStructModels) within $n_hours hours. Dataflowing to the next level capacity.");
        }
    }
    if ($command->exit_code) {
        if ($command->err =~ /raxmlHPC-AVX: optimizeModel\.c:123: setRateModel: Assertion `rate >= RATE_MIN && rate <= RATE_MAX' failed\./) {
            # This is the fix suggested in https://github.com/stamatak/standard-RAxML/issues/39
            # NOTE: v8.2.10+ of RAxML already includes this fix, so this handler can be removed if updated
            return $self->_run_bootstrap_raxml('use_no_bgfs');
        } else {
            $command->die_with_log;
        }
    }

  my $bootstrap_msec = int(time()*1000-$bootstrap_starttime);

  my $ideal_msec = 30000; # 5 minutes
  my $time_per_sample = $bootstrap_msec / $bootstrap_num;
  my $ideal_bootstrap_num = $ideal_msec / $time_per_sample;
  if ($ideal_bootstrap_num < 10) {
    if   ($ideal_bootstrap_num < 5) { $self->param('bootstrap_num',  1); }
    else                            { $self->param('bootstrap_num', 10); }
  } elsif ($ideal_bootstrap_num > 100) {
    $self->param('bootstrap_num', 100);
  } else {
    $self->param('bootstrap_num', int($ideal_bootstrap_num) );
  }

  my $raxml_output = $self->worker_temp_directory . "/RAxML_bestTree." . "$raxml_tag.$bootstrap_num";

  $self->store_newick_into_nc_tree('ml_it_'.$bootstrap_num, $raxml_output);

  # Unlink run files
  $temp_regexp = $temp_dir."*$raxml_tag.$bootstrap_num.RUN.*";
  $self->run_command("rm -f $temp_regexp");
  return 1;
}


1;
