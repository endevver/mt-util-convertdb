package MT::ConvertDB::ClassMgr {
    use MT::ConvertDB::ToolSet;
    use List::MoreUtils qw( uniq );
    use Class::Load qw( try_load_class load_first_existing_class );
    use vars qw( $l4p );

    has include_classes => (
        is        => 'rw',
        lazy      => 1,
        predicate => 1,
        builder   => 1,
    );

    has [qw( include_tables exclude_tables exclude_classes )] => (
        is        => 'rw',
        default   => sub { [] },
        lazy      => 1,
        predicate => 1,
    );

    has class_hierarchy => ( is => 'lazy', );

    has object_classes => (
        is  => 'lazy',
        isa => quote_sub(
            q( my ($v) = @_; ( defined($v) and ref($v) eq 'ARRAY' )
                               || die "object_classes is not an ARRAY ref"; )
        ),
        builder => 1
    );

    has object_keys => (
        is  => 'rw',
        isa => quote_sub(
            q(
            ref $_[0] eq 'HASH' or die 'object_keys is not a HASH ref';
        )
        ),
        default => sub { {} },
    );

    sub _build_include_classes {
        [   'CustomFields::Field', 'MT::PluginData',
            @{ shift->object_classes }
        ];
    }

    my %class_objects_generated;

    sub class_objects {
        my $self = shift;
        Carp::confess("Extra arguments passed to class_objects") if @_;
        my ( $include, $exclude, $excludeds ) = @_;
        ###l4p $l4p ||= get_logger(); $l4p->trace();

        %class_objects_generated = ();    # Init or re-init

        if ( $self->has_include_tables || $self->has_include_classes ) {
            $include ||= [
                uniq @{
                    $self->has_include_classes ? $self->include_classes : []
                },
                @{ $self->_tables_to_classes( $self->include_tables ) },
            ];

            # say "INCLUDE: ".p($include);
        }
        else {
            $exclude ||= [
                uniq @{ $self->exclude_classes || [] },
                @{  $self->_tables_to_classes( $self->exclude_tables || [] )
                },
            ];

            # $self->exclude_classes($exclude);
            # say "EXCLUDE: ".p($exclude);

            $include = [
                grep { !( $_ ~~ $exclude ) }
                    @{ $self->include_classes }    # Uses default
            ];

            # say "INCLUDE FILTERED: ".p($include);
        }

        # $self->include_classes($include);
        # say "INCLUDE: ".p($include);
        return [ map { $self->_mk_class_objects($_) } @$include ];
    }

    sub _tables_to_classes {
        my ( $self, $tables ) = ( @_, [] );
        return [ grep { $_->properties->{datasource} ~~ $tables }
                @{ $self->object_classes } ];
    }

    sub _mk_class_objects {
        my $self  = shift;
        my $class = shift;
        return if $class_objects_generated{$class}++;
        ###l4p $l4p->debug("Generating class object for $class");

        my $class_hierarchy = $self->class_hierarchy;

        my @parents = map { $self->_mk_class_objects($_) }
            @{ $class_hierarchy->{$class}{parents} };

        return ( @parents, $self->class_object($class) );
    }

    sub class_object {
        my $self  = shift;
        my $class = shift;
        state $cache = {};
        unless ( $cache->{$class} ) {
            ( my $objclass = $class ) =~ s{^(MT::)?}{ref($self).'::'}e;
            my $obj = $cache->{$class}
                = load_first_existing_class( $objclass,
                ref($self) . '::Generic' )->new( class => $class );
            ###l4p $l4p->info("Using ".ref($obj)." for $class objects");
        }
        $cache->{$class};
    }

    sub post_migrate { }

    sub _build_object_classes {
        ###l4p $l4p ||= get_logger(); $l4p->trace(1);
        return [
            uniq sort map { MT->model($_) }
                keys %{ MT->registry('object_types') }
        ];
    }

    sub _build_class_hierarchy {
        my $self = shift;
        ###l4p $l4p ||= get_logger(); $l4p->trace(1);

        my $classes   = $self->object_classes;
        my $class_map = {};

        my %processed;
        foreach my $class (@$classes) {
            next if $processed{$class}++;
            ###l4p $l4p->debug("Mapping $class");
            use_package_optimistically($class);
            $class_map->{$class}{parents} ||= [];

            if ( my @kids = $self->_parse_child_classes($class) ) {
                $class_map->{$class}{children} = [@kids];
                push( @{ $class_map->{$_}{parents} ||= [] }, $class )
                    for @kids;
            }
        }

        @{ $_->{parents} } = uniq( @{ $_->{parents} } )
            for values %$class_map;

        ###l4p $l4p->debug('Class map: '.p($class_map));
        return $class_map;
    }

    sub _parse_child_classes {
        my ( $self, $class ) = @_;

        my $props_children = $class->properties->{child_classes};
        return unless $props_children;

        my $reftype = ref($props_children);

        if ( grep { $_ eq $reftype } qw( HASH ARRAY ) ) {
            return uniq(
                $reftype eq 'HASH'
                ? keys %{$props_children}
                : @{$props_children}
            );
        }

        $l4p->warn(
            "Unrecognized child_classes reference $reftype for $class: ",
            l4mtdump($props_children) );
        return;
    }
}

package MT::ConvertDB::Role::SimpleSave {
    use Moo::Role;

    sub save_method {
        sub { shift; shift->save }
    }
}

package MT::ConvertDB::Role::DefaultSave {
    use Moo::Role;

    sub save_method {
        return sub {
            my ( $self, $obj ) = @_;
            my $save = MT::Object->can('save');
            $obj->$save;
            }
    }
}

package MT::ConvertDB::ClassMgr::Generic {
    use MT::ConvertDB::ToolSet;
    use List::Util qw( reduce );
    extends 'MT::ConvertDB::ClassMgr';
    with 'MT::ConvertDB::Role::DefaultSave';
    use vars qw( $l4p );

    has class => (
        is  => 'ro',
        isa => quote_sub(q( defined($_[0]) or die "class not defined";  )),
    );

    has metacolumns => (
        is        => 'lazy',
        predicate => 1,
        clearer   => 1,
    );

    has ds => (
        is  => 'lazy',
        isa => quote_sub(q( defined($_[0]) or die "datasource not defined" )),
    );

    has table => (
        is  => 'lazy',
        isa => quote_sub(q( defined($_[0]) or die "table not defined" )),
    );

    has mpkg => ( is => 'lazy', );

    has mds => ( is => 'lazy', );

    has mtable => ( is => 'lazy', );

    sub _build_ds { shift->class->datasource }

    sub _build_table { 'mt_' . ( shift->ds ) }

    sub _build_mpkg {
        my $self  = shift;
        my $class = $self->class;
        my @isa   = try { no strict 'refs'; @{ $class . '::ISA' } };
        return unless grep { $_ eq 'MT::Object' } @isa;

        require MT::Meta;
        return MT::Meta->has_own_metadata_of($class)
            ? $class->meta_pkg
            : undef;
    }

    sub _build_mds {
        my $self = shift;
        try { $self->mpkg->datasource };
    }

    sub _build_mtable {
        my $self = shift;
        return $self->mds ? 'mt_' . ( $self->mds ) : undef;
    }

    sub _build_metacolumns {
        my $self = shift;
        require MT::Meta;
        return [ try { MT::Meta->metadata_by_class( $self->class ) } ];
    }

    sub _trigger_class {
        my $self  = shift;
        my $class = shift;
        $self->clear_metacolumns
            unless defined( $self->metacolumns )
            && @{ $self->metacolumns };
    }

    sub reset_object_drivers {
        my $self  = shift;
        my $class = $self->class;
        undef $class->properties->{driver};
        try { undef $class->meta_pkg->properties->{driver} };
    }

    sub count {
        my $self = shift;
        my ( $terms, $args ) = @_;
        my $class = $self->class;
        $self->reset_object_drivers();
        return $class->count( $terms, $args ) || 0;
    }

    sub meta_count {
        my $self  = shift;
        my $class = $self->class;
        return unless $class->meta_pkg && $class->has_meta;
        $self->reset_object_drivers();
        return ( $class->meta_pkg->count() || 0 );
    }

    sub remove_all {
        my $self = shift;
        my $class = shift || $self->class;
        ###l4p $l4p ||= get_logger();
        ###l4p $l4p->info(sprintf('Removing all %s objects from mt_%s table',
        ###l4p     $class, $class->properties->{datasource} ));

        $self->remove_all( $class->meta_pkg ) if $class->meta_pkg;

        MT::Object->driver->direct_remove($class);

        if ( my $remaining = $class->count ) {
            $l4p->error( $remaining . " rows remaining in $class table" );
        }
    }

    sub load_object {
        my $self = shift;
        $self->load( $self->primary_key_to_terms( +shift ) );
    }

    sub load {
        my $self = shift;
        my ( $terms, $args ) = @_;
        my $class = $self->class;
        ###l4p $l4p ||= get_logger();
        ###l4p $l4p->debug(sprintf('Loading %s objects (%s)', $class, ref($self) ));
        $self->class->load( $terms, $args );
    }

    sub load_iter {
        my $self = shift;
        my ( $terms, $args ) = @_;
        my $class = $self->class;
        ###l4p $l4p ||= get_logger();
        ###l4p $l4p->debug(sprintf('Getting iter for %s objects (%s)', $class, ref($self) ));
        my $iter = $self->class->load_iter( $terms, $args );
    }

    sub load_meta {
        my $self = shift;
        my ($obj) = @_;
        return {} unless $obj and $obj->has_meta;
        ###l4p $l4p ||= get_logger();
        $self->reset_object_drivers($obj);

        ### TODO Revisions???
        ### TODO Summaries???

        my $meta = { %{ $obj->meta } } || {};
        foreach my $fld ( keys %$meta ) {
            $obj->meta( $fld, ( $meta->{$fld} // undef ) );
        }
        return $obj->meta;
    }

    sub save {
        my ( $self, $obj, $metadata ) = @_;
        ###l4p $l4p ||= get_logger();
        ###l4p $l4p->debug(sprintf( 'Saving %s%s', $self->class,
        ###l4p     ( $obj->has_column('id') ? ' ID '.$obj->id : '.' )
        ###l4p ));
        $self->reset_object_drivers();

        my $defs = $obj->column_defs;

        foreach my $col ( keys %{$defs} ) {
            my $def = $defs->{$col};
            if ( $def->{type} =~ /(?:integer|smallint)/ && $obj->$col ) {
                my $val = $obj->$col;
                if ( $val =~ /\D/ ) {
                    $val =~ s/\D//g;
                    $obj->$col($val);
                }
            }
            if ( $def->{type} =~ /(?:string)/ && $obj->$col ) {
                require MT::I18N;
                my $val = $obj->$col;
                if ( MT::I18N::length_text($val) > $def->{size} ) {
                    $obj->$col(
                        MT::I18N::substr_text( $val, 0, $def->{size} ) );
                }
            }
        }

        my $save = $self->save_method;
        unless ( $self->$save($obj) ) {
            $l4p->error( "Failed to save record for class "
                    . $self->class . ": "
                    . ( $obj->errstr || 'UNKNOWN ERROR' ) );
            $l4p->error( 'Object: ' . p($obj) );
            exit 1;
        }
        return $obj;
    }

=head2 object_diff

object_diff is a method responsible for comparing old and new versions of the
same object, or alternately, a hash of their values.  If you have two objects
and, optionally, their metadata (as in MT::ConvertDB::CLI::verify_migration),
you call it like so:

        $classmgr->object_diff(
            objects => [ $old,     $new     ],
            meta    => [ $oldmeta, $newmeta ],    # optional
        );

=head3 Comparing object values hashes

In addition, you can also call on this method to compare two values hashes
dumped from an object (e.g. MT::ConvertDB::ClassMgr::Config) in which case
you call it like so:

        $classmgr->object_diff(
            class  => ref($obj),
            pk_str => $obj->pk_str,
            data   => [ \%old,    \%new    ],
            meta   => [ $oldmeta, $newmeta ],    # optional
        );

Or, more concisely:

        $classmgr->object_diff(
            object => $obj,
            data   => [ \%old,    \%new    ],
            meta   => [ $oldmeta, $newmeta ],    # optional
        );

=cut

    sub object_diff {
        my $self = shift;
        my %args = @_;
        ###l4p $l4p ||= get_logger();

        my ( $old, $new, $class );

        #
        # Object validation
        #
        if ( $args{objects} ) {
            ( $old, $new ) = @{ $args{objects} };
            $args{class} = $class = ref $old;
            $args{old} = $old->get_values();
            $args{new} = $new->get_values() if $new;
        }
        elsif ( $args{object} ) {
            my $obj = $args{object};
            $args{class} ||= ref $obj;
            $args{pk_str} ||= $obj->pk_str || '';
        }

        if ( $args{new} ) {
            $self->_object_diff(%args);
        }
        else {
            $l4p->error( "$class object not migrated: ", l4mtdump($old) );
            return 1;
        }

        #
        # Metadata validation
        #
        if (my @meta = map { keys %$_ }
            grep { ref $_ eq 'HASH' } @{ $args{meta} }
            )
        {

            $self->_object_diff(
                %args,
                class => $args{class}->meta_pkg,
                old   => $args{meta}->[0],
                new   => $args{meta}->[1],
            );
        }

        return 1;
    }

=head2 _object_diff( old => \%old, new => \%new, class => $class, pk_str => $pk_str )

This method is responsible for iterating over two possibly-nested hashes in
order to extract values for comparison.  All hash/array references are recursively
dereferenced but code references and blessed objects are ignored.

=cut

    sub _object_diff {
        my $self = shift;
        my %d    = @_;

        foreach my $k ( keys %{ $d{old} } ) {
            ###l4p $l4p->debug(join(' ',
            ###l4p     'Comparing', $d{class}, ($d{pk_str} ? $d{pk_str} : ()), $k, 'meta values'));
            my $diff;
            my $old = $d{old}->{$k} // '';
            my $new = $d{new}->{$k} // '';

            if ( !ref $old ) {
                $diff = DBI::data_diff( $old, $new );
            }
            else {
                $l4p->debug( 'Using Test::Deep::NoTest::eq_deeply for '
                        . $d{class}
                        . ' object comparison.' );
                require Test::Deep::NoTest;
                import Test::Deep::NoTest;
                $diff = eq_deeply( $old, $new ) ? '' : 1;
            }

            $diff
                && $self->report_diff( %d, key => $k, diff => $diff );
        }
    }

    sub report_diff {
        my $self = shift;
        my %d    = @_;
        my $diff = $d{diff};
        my $key  = $d{key};
        my $vold = $d{args}->{old}{$key} // '';
        my $vnew = $d{args}->{new}{$key} // '';

        unless ( $vold . $vnew eq '' ) {
            $l4p->error(
                sprintf(
                    'Data difference detected in %s ID %s %s',
                    $d{class}, ( $d{pk_str} // '' ),
                    $key, $diff
                )
            );
            $l4p->error($diff);
            $l4p->error( 'a: ', ref($vold) ? l4mtdump($vold) : $vold );
            $l4p->error( 'b: ', ref($vnew) ? l4mtdump($vnew) : $vnew );
            $l4p->error( 'a object: ', l4mtdump( $d{args}->{old} ) );
        }
    }

    sub post_migrate_class { }

    sub primary_key_to_terms { $_[1]->primary_key_to_terms }
}

package MT::ConvertDB::ClassMgr::CustomField::Field {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';

    after save => sub { $_[1]->add_meta };
}

# package MT::ConvertDB::ClassMgr::Template;
#
# use MT::ConvertDB::ToolSet;
# extends 'MT::ConvertDB::ClassMgr::Generic';
#
# use vars qw( $l4p );
#
# before save => sub {
#     my ( $self, $obj, $metadata ) = @_;
#     ###l4p $l4p ||= get_logger(); $l4p->trace(1);
#
#     my $object_keys = $self->object_keys;
#
#     ## Look for duplicate template names, because
#     ## we have uniqueness constraints in the DB.
#     my $key = $obj->blog_id . ':' . lc( $obj->name );
#     if ( $object_keys->{$key}++ ) {
#         print "        Found duplicate template name '" . $obj->name;
#         $obj->name( $obj->name . ' ' . $object_keys->{$key} );
#         print "'; renaming to '" . $obj->name . "'\n";
#     }
#     ## Touch the text column to make sure we read in
#     ## any linked templates.
#     my $text = $obj->text;
# };
#
# #############################################################################

package MT::ConvertDB::ClassMgr::Author {
    use MT::Util;
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';
    use vars qw( $l4p );
    before save => sub {
        my ( $self, $obj, $metadata ) = @_;
        ###l4p $l4p ||= get_logger(); $l4p->trace();
        my $class       = $self->class;
        my $object_keys = $self->object_keys;

        ## Look for duplicate author names, because
        ## we have uniqueness constraints in the DB.
        my $key
            = lc(  $obj->name
                || $obj->basename
                || MT::Util::make_unique_author_basename($obj) );
        if ( $object_keys->{ $class . $obj->type }{$key}++ ) {
            my $orig = $obj->name;
            $obj->name(
                join( ' ',
                    $obj->name, $object_keys->{ $class . $obj->type }{$key} )
            );
            $l4p->warn( 'Found duplicate author name '
                    . $orig
                    . '; renaming to '
                    . $obj->name );
        }
        $obj->email('')        unless defined $obj->email;
        $obj->set_password('') unless defined $obj->password;
    };
}

package MT::ConvertDB::ClassMgr::Comment {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';
    before save => sub { $_[1]->visible(1) unless defined $_[1]->visible };
}

package MT::ConvertDB::ClassMgr::TBPing {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';
    before save => sub { $_[1]->visible(1) unless defined $_[1]->visible };
}

package MT::ConvertDB::ClassMgr::Trackback {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';
    before save => sub {
        my ( $self, $obj, $metadata ) = @_;
        $obj->entry_id(0)    unless defined $obj->entry_id;
        $obj->category_id(0) unless defined $obj->category_id;
    };
}

package MT::ConvertDB::ClassMgr::Entry {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';
    before save => sub {
        my ( $self, $obj, $metadata ) = @_;
        $obj->allow_pings(0)
            if defined( $obj->allow_pings ) && $obj->allow_pings eq '';
        $obj->allow_comments(0)
            if defined( $obj->allow_comments )
            && ( $obj->allow_comments eq '' );
    };
}

package MT::ConvertDB::ClassMgr::Page {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Entry';
}

package MT::ConvertDB::ClassMgr::Session {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';
    with 'MT::ConvertDB::Role::SimpleSave';
}

package MT::ConvertDB::ClassMgr::Config {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';

    sub object_diff {
        my $self = shift;
        my %args = @_;

        # ##l4p $l4p ||= get_logger();

        my ( $old, $new ) = @{ $args{objects} };

        $self->SUPER::object_diff(
            class  => ref($old),
            pk_str => $old->pk_str,
            old    => $self->_parse_db_config($old),
            new    => $self->_parse_db_config($new),
        );
    }

    sub _parse_db_config {
        my $self = shift;
        my @data = split /[\r?\n]/, shift()->data;
        my %data = ();
        foreach (@data) {
            chomp;
            next if !/\S/ || /^#/;
            my ( $var, $val ) = $_ =~ /^\s*(\S+)\s+(.+)$/;
            $val =~ s/\s*$// if defined($val);
            next unless $var && defined($val);
            next if $var eq 'SchemaVersion';  # We modify this in post_migrate
            if ( defined( $data{$var} ) ) {
                if ( ref( $data{$var} ) ne 'HASH' ) {
                    my ( $k, $v ) = $data{$var} =~ m/(.+?)=(.+?)/;
                    $data{$var} = { $k => $v };
                }
                if ( my ( $k, $v ) = $val =~ m/(.+?)=(.+?)/ ) {
                    $data{$var}->{$k} = $v;
                }
            }
            else {
                $data{$var} = $val;
            }
        }

        # p(%data);
        return \%data;
    }
}

package MT::ConvertDB::ClassMgr::Bob::Job {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';

    sub report_diff {
        my $self = shift;
        my %args = @_;

        # last_run and next_run are reported as migration errors
        # if RPT is run after migration but before verification
        return $self->SUPER::report_diff(@_)
            unless $args{key} =~ m{(next|last)_run};
    }
}

package MT::ConvertDB::ClassMgr::TheSchwartz::Error {
    use MT::ConvertDB::ToolSet;
    extends 'MT::ConvertDB::ClassMgr::Generic';

    sub save_method {
        return sub {
            my $self = shift;
            my $obj  = shift;
            $obj->driver->insert($obj);
            }
    }

    sub primary_key_to_terms {
        my $self = shift;
        my $obj  = shift;
        return { map { $_ => $obj->$_ } qw(error_time jobid funcid) };
    }
}
1;
