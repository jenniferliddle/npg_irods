package WTSI::NPG::HTS::AncFileDataObjectTest;

use strict;
use warnings;

use Carp;
use English qw(-no_match_vars);
use File::Basename;
use File::Spec::Functions;
use File::Temp;
use List::AllUtils qw(any);
use Log::Log4perl;
use Test::More;

use base qw(WTSI::NPG::HTS::Test);

Log::Log4perl::init('./etc/log4perl_tests.conf');

use WTSI::NPG::HTS::AncFileDataObject;
use WTSI::NPG::HTS::LIMSFactory;
use WTSI::NPG::iRODS::Metadata;
use WTSI::NPG::iRODS;

{
  package TestDB;
  use Moose;

  with 'npg_testing::db';
}

my $test_counter = 0;
my $data_path = './t/data/anc_file_data_object';
my $fixture_path = "./t/fixtures";

my $wh_attr = {RaiseError    => 1,
               on_connect_do => 'PRAGMA encoding = "UTF-8"'};

my $db_dir = File::Temp->newdir;
my $wh_schema;
my $lims_factory;

my $irods_tmp_coll;

my $have_admin_rights =
  system(qq{$WTSI::NPG::iRODS::IADMIN lu >/dev/null 2>&1}) == 0;

# The public group
my $public_group = 'public';
# Prefix for test iRODS data access groups
my $group_prefix = 'ss_';

# Filter for recognising test groups
my $group_filter = sub {
  my ($group) = @_;
  if ($group eq $public_group or $group =~ m{^$group_prefix}) {
    return 1
  }
  else {
    return 0;
  }
};

# Groups to be added to the test iRODS
my @irods_groups = map { $group_prefix . $_ }
  (10, 100, 198, 619, 2967, 3291, 3720);
push @irods_groups, $public_group;

# Groups added to the test iRODS in fixture setup
my @groups_added;
# Enable group tests
my $group_tests_enabled = 0;

my $pid = $PID;

my $formats = {bamcheck  => [q[]],
               bed       => ['.deletions', '.insertions', '.junctions'],
               seqchksum => [q[], '.sha512primesums512'],
               stats     => ['_F0x900', '_F0xB00'],
               txt       => ['_quality_cycle_caltable',
                             '_quality_cycle_surv',
                             '_quality_error']};

my @tag0_files;
my @tag1_files;
foreach my $format (sort keys %$formats) {
  foreach my $part (@{$formats->{$format}}) {
    if ($format eq 'bed') {
      push @tag1_files, sprintf '17550_3#1%s.%s',    $part, $format;
    }
    else {
      push @tag0_files, sprintf '17550_3#0%s.%s',      $part, $format;
      push @tag0_files, sprintf '17550_3#0_phix%s.%s', $part, $format;
      push @tag1_files, sprintf '17550_3#1_phix%s.%s', $part, $format;
    }
  }
}

sub setup_databases : Test(startup) {
  my $wh_db_file = catfile($db_dir, 'ml_wh.db');
  my $wh_attr = {RaiseError    => 1,
                 on_connect_do => 'PRAGMA encoding = "UTF-8"'};

  {
    # create_test_db produces warnings during expected use, which
    # appear mixed with test output in the terminal
    local $SIG{__WARN__} = sub { };
    $wh_schema = TestDB->new(test_dbattr => $wh_attr)->create_test_db
      ('WTSI::DNAP::Warehouse::Schema', "$fixture_path/ml_warehouse",
       $wh_db_file);
  }

  $lims_factory = WTSI::NPG::HTS::LIMSFactory->new(mlwh_schema => $wh_schema);
}

sub teardown_databases : Test(shutdown) {
  $wh_schema->storage->disconnect;
}

sub setup_test : Test(setup) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);

  $irods_tmp_coll =
    $irods->add_collection("AncFileDataObjectTest.$pid.$test_counter");
  $test_counter++;

  my $group_count = 0;
  foreach my $group (@irods_groups) {
    if ($irods->group_exists($group)) {
      $group_count++;
    }
    else {
      if ($have_admin_rights) {
        push @groups_added, $irods->add_group($group);
        $group_count++;
      }
    }
  }

  if ($group_count == scalar @irods_groups) {
    $group_tests_enabled = 1;
  }

  $irods->put_collection($data_path, $irods_tmp_coll);

  foreach my $data_file (@tag0_files, @tag1_files) {
    my $path = "$irods_tmp_coll/anc_file_data_object/$data_file";
    if ($group_tests_enabled) {
      # Add some test group permissions
      $irods->set_object_permissions($WTSI::NPG::iRODS::READ_PERMISSION,
                                     $public_group, $path);
      foreach my $group (map { $group_prefix . $_ } (10, 100)) {
        $irods->set_object_permissions
          ($WTSI::NPG::iRODS::READ_PERMISSION, $group, $path);
      }
    }
  }
}

sub teardown_test : Test(teardown) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);
  # $irods->remove_collection($irods_tmp_coll);

  # if ($have_admin_rights) {
  #   foreach my $group (@groups_added) {
  #     if ($irods->group_exists($group)) {
  #       $irods->remove_group($group);
  #     }
  #   }
  # }
}

sub require : Test(1) {
  require_ok('WTSI::NPG::HTS::AncFileDataObject');
}

my @untagged_paths = ('/seq/17550/17550_3',
                      '/seq/17550/17550_3_human',
                      '/seq/17550/17550_3_nonhuman',
                      '/seq/17550/17550_3_yhuman',
                      '/seq/17550/17550_3_phix');
my @tagged_paths   = ('/seq/17550/17550_3#1',
                      '/seq/17550/17550_3#1_human',
                      '/seq/17550/17550_3#1_nonhuman',
                      '/seq/17550/17550_3#1_yhuman',
                      '/seq/17550/17550_3#1_phix');

sub id_run : Test(110) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);

  foreach my $format (sort keys %{$formats}) {
    foreach my $path (@tagged_paths, @untagged_paths) {
      foreach my $part (@{$formats->{$format}}) {
        my $full_path = $path . $part . ".$format";
        cmp_ok(WTSI::NPG::HTS::AncFileDataObject->new
               ($irods, $full_path)->id_run,
               '==', 17550, "$full_path id_run is correct");
      }
    }
  }
}

sub position : Test(110) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);

  foreach my $format (sort keys %{$formats}) {
    foreach my $path (@tagged_paths, @untagged_paths) {
      foreach my $part (@{$formats->{$format}}) {
        my $full_path = $path . $part . ".$format";
        cmp_ok(WTSI::NPG::HTS::AncFileDataObject->new
               ($irods, $full_path)->position,
               '==', 3, "$full_path position is correct");
      }
    }
  }
}

sub tag_index : Test(110) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);

  foreach my $format (sort keys %{$formats}) {
    foreach my $path (@tagged_paths) {
      foreach my $part (@{$formats->{$format}}) {
        my $full_path = $path . $part . ".$format";
        cmp_ok(WTSI::NPG::HTS::AncFileDataObject->new
               ($irods, $full_path)->tag_index,
               '==', 1, "$full_path tag_index is correct");
      }
    }
  }

  foreach my $format (sort keys %{$formats}) {
    foreach my $path (@untagged_paths) {
      foreach my $part (@{$formats->{$format}}) {
        my $full_path = $path . $part . ".$format";
        is(WTSI::NPG::HTS::AncFileDataObject->new
           ($irods, $full_path)->tag_index, undef,
           "$full_path tag_index 'undef' is correct");
      }
    }
  }
}

sub align_filter : Test(110) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);

  foreach my $format (sort keys %{$formats}) {
    foreach my $path (@tagged_paths, @untagged_paths) {
      foreach my $part (@{$formats->{$format}}) {
        my $full_path = $path . $part . ".$format";
        my ($expected) = $path =~ m{_((human|nonhuman|yhuman|phix))};
        my $exp_str = defined $expected ? $expected : 'undef';

        my $align_filter = WTSI::NPG::HTS::AncFileDataObject->new
          ($irods, $full_path)->align_filter;

        is($align_filter, $expected,
           "$full_path align filter '$exp_str' is correct");
      }
    }
  }
}

sub update_secondary_metadata_tag1_no_spike_human : Test(44) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    group_prefix         => $group_prefix,
                                    group_filter         => $group_filter,
                                    strict_baton_version => 0,);

  my $tag1_expected_meta =
    [{attribute => $STUDY_NAME,
      value     => 'RNA sequencing of mouse haemopoietic cells 2014/15'},
     {attribute => $STUDY_ACCESSION_NUMBER,   value     => 'ERP006862'},
     {attribute => $STUDY_ID,                 value     => '3291'},
     {attribute => $STUDY_TITLE,
      value     => 'RNA sequencing of mouse haemopoietic cells 2014/15'}];

  my $spiked_control = 0;

  foreach my $data_file (@tag1_files) {
    my ($name, $path, $suffix) = fileparse($data_file, '.bed', '.json');

    my @expected_metadata;
    my @expected_groups_after;
    if (any { $suffix eq $_ } ('.bed', '.json')) {
      push @expected_metadata, @$tag1_expected_meta;
      push @expected_groups_after, 'ss_3291';
    }
    else {
      push @expected_groups_after, $public_group;
    }

    test_metadata_update($irods, "$irods_tmp_coll/anc_file_data_object",
                         {data_file              => $data_file,
                          spiked_control         => $spiked_control,
                          expected_metadata      => \@expected_metadata,
                          expected_groups_before => [$public_group,
                                                     'ss_10',
                                                     'ss_100'],
                          expected_groups_after  => \@expected_groups_after});
  }
}

sub test_metadata_update {
  my ($irods, $working_coll, $args) = @_;

  ref $args eq 'HASH' or croak "The arguments must be a HashRef";

  my $data_file      = $args->{data_file};
  my $spiked         = $args->{spiked_control};
  my $exp_metadata   = $args->{expected_metadata};
  my $exp_grp_before = $args->{expected_groups_before};
  my $exp_grp_after  = $args->{expected_groups_after};

  my $obj = WTSI::NPG::HTS::AncFileDataObject->new
    (collection  => $working_coll,
     data_object => $data_file,
     irods       => $irods);
  my $tag = $obj->tag_index;

  my @groups_before = $obj->get_groups;
  ok($obj->update_secondary_metadata($lims_factory, $spiked,),
     "Secondary metadata ran; $data_file, tag: $tag, spiked: $spiked");
  my @groups_after = $obj->get_groups;

  my $metadata = $obj->metadata;
  is_deeply($metadata, $exp_metadata,
            "Secondary metadata was updated; $data_file, " .
            "tag: $tag, spiked: $spiked")
    or diag explain $metadata;

 SKIP: {
    if (not $group_tests_enabled) {
      skip 'iRODS test groups were not present', 2;
    }
    else {
      is_deeply(\@groups_before, $exp_grp_before,
                'Groups before update') or diag explain \@groups_before;

      is_deeply(\@groups_after, $exp_grp_after,
                'Groups after update') or diag explain \@groups_after;
    }
  } # SKIP groups_added
}

1;
