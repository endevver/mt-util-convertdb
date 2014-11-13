package MT::ConvertDB::ClassMgr;

use MT::ConvertDB::ToolSet;
use List::MoreUtils qw( uniq );
use Class::Load qw( try_load_class load_first_existing_class );
use vars qw( $l4p );

has object_classes => (
    is      => 'lazy',
    isa     => quote_sub(q( my ($v) = @_; ( defined($v) and ref($v) eq 'ARRAY' ) || die "object_classes is not an ARRAY ref"; )),
    builder => 1
);

has class_hierarchy => (
    is => 'lazy',
);

my %class_objects_generated;

sub class_objects {
    my $self    = shift;
    my $classes = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace();

    %class_objects_generated = ();
    @$classes or $classes = [
        'CustomFields::Field', 'MT::PluginData', @{$self->object_classes}
    ];
    return [ map { $self->_mk_class_objects($_) } @$classes ];
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
    my $self     = shift;
    my $class    = shift;
    state $cache = {};
    unless ( $cache->{$class} ) {
        (my $objclass = $class) =~ s{^(MT::)?}{ref($self).'::'}e;
        my $obj = $cache->{$class}
            = load_first_existing_class( $objclass, ref($self).'::Generic' )
                ->new( class => $class );
        ###l4p $l4p->info("Using ".ref($obj)." for $class objects");
    }
    $cache->{$class};
}

sub post_migrate { }

sub _build_object_classes {
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    my @classes;
    my $types = MT->registry('object_types'); # p($types);
    foreach my $type ( keys %$types ) {
        # object_types value is either a class or an array ref with class as first element
        push(@classes,
             ref($types->{$type}) ? $types->{$type}[0] : $types->{$type} );
    }
    return [ uniq sort @classes ];
}

sub _build_class_hierarchy {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);

    my $classes   = $self->object_classes;
    my $class_map = {};

    my %processed;
    foreach my $class ( @$classes ) {
        next if $processed{$class}++;
        ###l4p $l4p->debug("Mapping $class");
        use_package_optimistically( $class );
        $class_map->{$class}{parents} ||= [];

        if ( my @kids = $self->_parse_child_classes( $class ) ) {
            $class_map->{$class}{children}       = [ @kids ];
            push( @{ $class_map->{$_}{parents} ||= [] }, $class ) for @kids;
        }
    }

    @{$_->{parents}} = uniq( @{$_->{parents}} )
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
            $reftype eq 'HASH' ? keys %{$props_children} : @{$props_children}
        );
    }

    $l4p->warn( "Unrecognized child_classes reference $reftype for $class: ",
                l4mtdump($props_children) );
    return;
}

#############################################################################

package MT::ConvertDB::Role::SimpleSave {

    use Moo::Role;

    sub save_method {
        sub { shift; shift->save }
    }
}

#############################################################################

package MT::ConvertDB::Role::DefaultSave {

    use Moo::Role;

    sub save_method {
        return sub {
            my ($self, $obj) = @_;
            my $save = MT::Object->can('save');
            $obj->$save;
        }
    }
}

#############################################################################

package MT::ConvertDB::ClassMgr::Generic;

use MT::ConvertDB::ToolSet;
use List::Util qw( reduce );
extends 'MT::ConvertDB::ClassMgr';
with 'MT::ConvertDB::Role::DefaultSave';
use vars qw( $l4p );

has object_keys => (
    is => 'rw',
    isa => quote_sub(q(
        ref $_[0] eq 'HASH' or die 'object_keys is not a HASH ref';
    )),
    default => sub { {} },
);

has class => (
    is      => 'ro',
    isa     => quote_sub(q( defined($_[0]) or die "class not defined";  )),
);

has metacolumns => (
    is        => 'lazy',
    predicate => 1,
    clearer   => 1,
);

sub _build_metacolumns {
    my $self = shift;
    require MT::Meta;
    return [ try { MT::Meta->metadata_by_class($self->class) } ];
}

sub _trigger_class {
    my $self = shift;
    my $class = shift;
    $self->clear_metacolumns unless defined($self->metacolumns)
                                 && @{ $self->metacolumns };
}

sub reset_object_drivers {
    my $self  = shift;
    my $class = $self->class;
    undef $class->properties->{driver};
    try { undef $class->meta_pkg->properties->{driver}            };
    # try { undef $class->revision_pkg->properties->{driver}        };
    # try { undef $class->meta_pkg('summary')->properties->{driver} };
}

sub count {
    my $self  = shift;
    my $class = shift || $self->class;
    my ($terms, $args) = @_;
    $self->reset_object_drivers();
    $class->count($terms, $args) || 0
}

sub meta_count {
    my $self  = shift;
    my $class = $self->class;
    return 0 unless $class->meta_pkg && $class->has_meta;
    $self->reset_object_drivers();
    return ($class->meta_pkg->count() || 0);
}

sub remove_all {
    my $self  = shift;
    my $class = shift || $self->class;
    my $count = $self->count($class);
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info(sprintf('Removing %d %s objects (%s)', $count, $class, ref($self) ));

    $self->remove_all( $class->meta_pkg ) if $class->meta_pkg;

    MT::Object->driver->direct_remove( $class );

    if (my $remaining = $class->count) {
        $l4p->error($remaining." rows remaining in $class table");
    }
}

sub load_object {
    my $self = shift;
    $self->load( $self->primary_key_to_terms(+shift) );
}

sub load {
    my $self  = shift;
    my ($terms, $args) = @_;
    my $class = $self->class;
    my $count = $self->count + $self->meta_count;
    ###l4p $l4p ||= get_logger();
    # ##l4p $l4p->info(sprintf('Loading %d %s objects (%s)', $count, $class, ref($self) ));
    $self->class->load($terms, $args)
}

sub load_iter {
    my $self = shift;
    my ($terms, $args) = @_;
    my $class = $self->class;
    my $count = $self->count + $self->meta_count;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info(sprintf('Getting iter for %d %s objects (%s)', $count, $class, ref($self) ));
    my $iter = $self->class->load_iter($terms, $args)
}

sub load_meta {
    my $self = shift;
    my ( $obj ) = @_;
    return {} unless $obj and $obj->has_meta;
    ###l4p $l4p ||= get_logger();
    $self->reset_object_drivers($obj);

    ### TODO Revisions???
    ### TODO Summaries???

    my $meta = { %{$obj->meta} } || {};

    defined($meta->{$_}) && $obj->meta( $_, $meta->{$_} ) foreach keys %$meta;

    return { meta => $meta };
}

sub save {
    my ( $self, $obj, $metadata ) = @_;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->debug(sprintf( 'Saving %s%s', $self->class,
    ###l4p     ( $obj->has_column('id') ? ' ID '.$obj->id : '.' )
    ###l4p ));
    $self->reset_object_drivers();

    my $defs = $obj->column_defs;

    foreach my $col (keys %{$defs}) {
        my $def = $defs->{$col};
        if ($def->{type} =~ /(?:integer|smallint)/ && $obj->$col) {
            my $val = $obj->$col;
            if ($val =~ /\D/) {
                $val =~ s/\D//g;
                $obj->$col($val);
            }
        }
        if ($def->{type} =~ /(?:string)/ && $obj->$col) {
            require MT::I18N;
            my $val = $obj->$col;
            if (MT::I18N::length_text($val) > $def->{size}) {
                $obj->$col(MT::I18N::substr_text($val,0,$def->{size}));
            }
        }
    }

    my $save = $self->save_method;
    unless ( $self->$save($obj) ) {
        $l4p->error("Failed to save record for class ".$self->class
                     . ": " . ($obj->errstr||'UNKNOWN ERROR'));
        $l4p->error('Object: '.p($obj));
        exit 1;
    }
    return $obj;
}

sub object_diff {
    my $self           = shift;
    my ($obj, $newobj, $oldmetadata, $newmetadata) = @_;
    ###l4p $l4p ||= get_logger();

    if ( ! $newobj ) {
        $l4p->error(ref($obj). ' object not migrated: ', l4mtdump($obj));
        return;
    }
    my $class  = ref($obj);
    my $pk_str = $obj->pk_str;

    foreach my $k ( keys %{$obj->get_values} ) {
        ###l4p $l4p->debug("Comparing $class $pk_str $k values");

        use Test::Deep::NoTest;
        my $diff = ref($obj->$k) ? (eq_deeply($obj->$k, $newobj->$k)?'':1)
                                 : DBI::data_diff($obj->$k, $newobj->$k);

        if ( $diff ) {
            unless (($obj->$k//'') eq '' and ($newobj->$k//'') eq '') {
                $l4p->error(sprintf(
                    'Data difference detected in %s ID %d %s!',
                    $class, $obj->id, $k, $diff
                ));
                $l4p->error($diff);
                $l4p->error('a: '.$obj->$k);
                $l4p->error('b: '.$newobj->$k);
            }
        }
    }

    my $oldmeta = $oldmetadata->{meta};
    my $newmeta = $newmetadata->{meta};
    foreach my $k ( keys %$oldmeta ) {
        ###l4p $l4p->debug("Comparing $class $pk_str $k meta values");
        use Test::Deep::NoTest;
        my $diff = ref($obj->$k) ? (eq_deeply($oldmeta->{$k}, $newmeta->{$k})?'':1)
                                 : DBI::data_diff($oldmeta->{$k}, $newmeta->{$k});

        if ( $diff ) {
            unless (($oldmeta->{$k}//'') eq '' and ($newmeta->{$k}//'') eq '') {
                $l4p->error(sprintf(
                    'Data difference detected in %s ID %d %s!',
                    $class, $obj->id, $k, $diff
                ));
                $l4p->error($diff);
                $l4p->error('a: '.$oldmeta->{$k});
                $l4p->error('b: '.$newmeta->{$k});
            }
        }
    }
    return 1;
}

sub post_migrate_class {}

sub full_record_counts {
    my $self = shift;
    my $c    = $self->class;
    no warnings 'once';
    my $tally = { obj  => $self->count(), meta => $self->meta_count() };
    $tally->{total} = reduce { $a + $tally->{$b} } qw( 0 obj meta );
    return $tally;
}

sub primary_key_to_terms { $_[1]->primary_key_to_terms }

#############################################################################

package MT::ConvertDB::ClassMgr::CustomField::Field;

use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';

after save => sub { $_[1]->add_meta };

#############################################################################

package MT::ConvertDB::ClassMgr::Template;

use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';

use vars qw( $l4p );

before save => sub {
    my ( $self, $obj, $metadata ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);

    my $object_keys = $self->object_keys;

    ## Look for duplicate template names, because
    ## we have uniqueness constraints in the DB.
    my $key = $obj->blog_id . ':' . lc($obj->name);
    if ($object_keys->{$key}++) {
        print "        Found duplicate template name '" .
              $obj->name;
        $obj->name($obj->name . ' ' . $object_keys->{$key});
        print "'; renaming to '" . $obj->name . "'\n";
    }
    ## Touch the text column to make sure we read in
    ## any linked templates.
    my $text = $obj->text;
};

#############################################################################

package MT::ConvertDB::ClassMgr::Author;

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
    my $key = lc($obj->name || $obj->basename || MT::Util::make_unique_author_basename($obj));
    if ($object_keys->{$class . $obj->type}{$key}++) {
        my $orig = $obj->name;
        $obj->name(join(' ', $obj->name, $object_keys->{$class . $obj->type}{$key}));
        $l4p->warn('Found duplicate author name '.$orig.'; renaming to '.$obj->name);
    }
    $obj->email('') unless defined $obj->email;
    $obj->set_password('') unless defined $obj->password;
};


#############################################################################

package MT::ConvertDB::ClassMgr::Comment;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';

before save => sub { $_[1]->visible(1) unless defined $_[1]->visible };

#############################################################################

package MT::ConvertDB::ClassMgr::TBPing;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';

before save => sub { $_[1]->visible(1) unless defined $_[1]->visible };

#############################################################################

package MT::ConvertDB::ClassMgr::Category;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';
use vars qw( $l4p );

has category_parents => (
    is => 'ro',
    isa => quote_sub(q(ref $_[0] eq 'HASH' or die 'category_parents is not a HASH ref'; )),
    default => sub { {} },
);

before save => sub {
    my ( $self, $obj, $metadata ) = @_;
    ###l4p $l4p ||= get_logger(); $l4p->trace();

    my $object_keys = $self->object_keys;

    ## Look for duplicate category names, because
    ## we have uniqueness constraints in the DB.
    my $key = lc($obj->label) . $obj->blog_id;
    if ($object_keys->{$key}++) {
        print "        Found duplicate category label '" .
              $obj->label;
        $obj->label($obj->label . ' ' . $object_keys->{$key});
        print "'; renaming to '" . $obj->label . "'\n";
    }
    # save the parent value for assignment at the end
    if ($obj->parent) {
        my $cat_parent = $self->category_parents;
        $cat_parent->{$obj->id} = $obj->parent;
        $obj->parent(0);
    }
};

sub post_migrate {
    my $self = shift;
    ###l4p $l4p ||= get_logger(); $l4p->trace(1);
    # fix up the category parents
    # $self->reset_object_drivers($obj);  ### FIXME Reset object drivers?
    my $cat_parent = $self->category_parents;
    foreach my $id (keys %$cat_parent) {
        my $cat = MT::Category->load($id);
        $cat->parent( $cat_parent->{$id} );
        $cat->save;
    }
}

#############################################################################

package MT::ConvertDB::ClassMgr::Folder;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Category';

#############################################################################

package MT::ConvertDB::ClassMgr::Trackback;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';

before save => sub {
    my ( $self, $obj, $metadata ) = @_;
    $obj->entry_id(0) unless defined $obj->entry_id;
    $obj->category_id(0) unless defined $obj->category_id;
};

#############################################################################

package MT::ConvertDB::ClassMgr::Entry;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';

before save => sub {
    my ( $self, $obj, $metadata ) = @_;
    $obj->allow_pings(0)
        if defined($obj->allow_pings) && $obj->allow_pings eq '';
    $obj->allow_comments(0)
        if defined($obj->allow_comments) && ($obj->allow_comments eq '');
};

#############################################################################

package MT::ConvertDB::ClassMgr::Page;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Entry';

#############################################################################

package MT::ConvertDB::ClassMgr::Session;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';
with 'MT::ConvertDB::Role::SimpleSave';

#############################################################################

package MT::ConvertDB::ClassMgr::Tag;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';

#############################################################################

package MT::ConvertDB::ClassMgr::TheSchwartz::Error;
use MT::ConvertDB::ToolSet;
extends 'MT::ConvertDB::ClassMgr::Generic';

sub save_method {
    get_logger->info(' TSERROR CUSTOM SAVE');
    return sub {
        my $self = shift;
        my $obj  = shift;
        $obj->driver->insert($obj);
    }
}

sub primary_key_to_terms {
    my $self = shift;
    my $obj = shift;
    return { map { $_ => $obj->$_ } qw(error_time jobid funcid) };
}

1;
