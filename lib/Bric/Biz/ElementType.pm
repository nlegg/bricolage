package Bric::Biz::ElementType;
###############################################################################

=head1 NAME

Bric::Biz::ElementType - Bricolage element types

=head1 VERSION

$LastChangedRevision$

=cut

require Bric; our $VERSION = Bric->VERSION;

=head1 DATE

$LastChangedDate$

=head1 SYNOPSIS

  # Create new types of assets.
  $element = Bric::Biz::ElementType->new($init)
  $element = Bric::Biz::ElementType->lookup({id => $id})
  ($at_list || @ats) = Bric::Biz::ElementType->list($param)
  ($id_list || @ids) = Bric::Biz::ElementType->list_ids($param)

  # Return the ID of this object.
  $id = $element->get_id()

  # Get/set this asset type's name.
  $element = $element->set_name( $name )
  $name       = $element->get_name()

  # Get/set the description for this asset type
  $element  = $element->set_description($description)
  $description = $element->get_description()

  # Get/set the primary output channel ID for this asset type.
  $element = $element->set_primary_oc_id($oc_id, $site_id);
  $oc_id = $element->get_primary_oc_id($site_id);

  # Attribute methods.
  $val  = $element->set_attr($name, $value);
  $val  = $element->get_attr($name);
  \%val = $element->all_attr;

  # Attribute metadata methods.
  $val = $element->set_meta($name, $meta, $value);
  $val = $element->get_meta($name, $meta);

  # Manage output channels.
  $element        = $element->add_output_channels([$output_channel])
  ($oc_list || @ocs) = $element->get_output_channels()
  $element        = $element->delete_output_channels([$output_channel])

  # Manage sites
  $element               = $element->add_sites([$site])
  ($site_list || @sites) = $element->get_sites()
  $element               = $element->remove_sites([$site])

  # Manage the parts of an element type.
  $element            = $element->add_field_types($field);
  $field_type         = $element->new_field_type($param);
  $element            = $element->copy_field_type($at, $field);
  ($part_list || @parts) = $element->get_field_types($field);
  $element            = $element->del_field_types($field);

  # Add, retrieve and delete containers from this asset type.
  $element            = $element->add_containers($at || [$at]);
  (@at_list || $at_list) = $element->get_containers();
  $element            = $element->del_containers($at || [$at]);

  # Get/set the active flag.
  $element  = $element->activate()
  $element  = $element->deactivate()
  (undef || 1) = $element->is_active()

  # Save this asset type.
  $element = $element->save()

=head1 DESCRIPTION

The element type class registers new type of elements that define the
structures of story and media documents. Element type objects are composed of
subelement types and fields, and top-level (story and media type) element
types are associated with sites and output channels to define how documents
based on them will be output and in what sites they can be created.

=cut

#==============================================================================#
# Dependencies                         #
#======================================#

#--------------------------------------#
# Standard Dependencies

use strict;

#--------------------------------------#
# Programatic Dependencies

use Bric::Util::DBI qw(:all);
use Bric::Util::Fault qw(throw_gen throw_dp);
use Bric::Util::Grp::ElementType;
use Bric::Util::Grp::SubelementType;
use Bric::Biz::ElementType::Parts::FieldType;
use Bric::Util::Attribute::ElementType;
use Bric::Biz::ATType;
use Bric::Util::Class;
use Bric::Biz::Site;
use Bric::Biz::OutputChannel::Element;
use Bric::Util::Coll::OCElement;
use Bric::Util::Coll::Site;
use Bric::App::Cache;
use List::Util qw(first);

#==============================================================================#
# Inheritance                          #
#======================================#

use base qw( Bric Exporter );

#=============================================================================#
# Function Prototypes                  #
#======================================#
my ($get_oc_coll, $get_site_coll, $remove, $make_key_name);

#==============================================================================#
# Constants                            #
#======================================#

use constant DEBUG             => 0;
use constant HAS_MULTISITE     => 1;
use constant GROUP_PACKAGE     => 'Bric::Util::Grp::ElementType';
use constant INSTANCE_GROUP_ID => 27;

use constant ORD => qw(name key_name description type_name  burner active);

# possible values for burner
use constant BURNER_MASON    => 1;
use constant BURNER_TEMPLATE => 2;
use constant BURNER_TT       => 3;
use constant BURNER_PHP      => 4;

#==============================================================================#
# Fields                               #
#======================================#

#--------------------------------------#
# Public Class Fields
our $METHS;
our @EXPORT_OK = qw(BURNER_MASON BURNER_TEMPLATE BURNER_TT BURNER_PHP);
our %EXPORT_TAGS = ( all => \@EXPORT_OK);

#--------------------------------------#
# Private Class Fields
my $table = 'element_type';
my $mem_table = 'member';
my $map_table = $table . "_$mem_table";
my @cols = qw(name key_name description burner reference type__id et_grp__id
              active);
my @props = qw(name key_name description burner reference type_id et_grp_id
               _active);
my $sel_cols = 'a.id, a.name, a.key_name, a.description, a.burner, '
    . 'a.reference, a.type__id, a.et_grp__id, a.active, m.grp__id';
my @sel_props = ('id', @props, 'grp_ids');

#--------------------------------------#
# Instance Fields

BEGIN {
    Bric::register_fields({
        id                  => Bric::FIELD_READ,
        et_grp_id           => Bric::FIELD_READ,
        key_name            => Bric::FIELD_RDWR,
        name                => Bric::FIELD_RDWR,
        description         => Bric::FIELD_RDWR,
        burner              => Bric::FIELD_RDWR,
        reference           => Bric::FIELD_READ,
        type_id             => Bric::FIELD_READ,
        grp_ids             => Bric::FIELD_READ,

        _site_primary_oc_id => Bric::FIELD_NONE,
        _active             => Bric::FIELD_NONE,
        _oc_coll            => Bric::FIELD_NONE,
        _site_coll          => Bric::FIELD_NONE,
        _parts              => Bric::FIELD_NONE,
        _new_parts          => Bric::FIELD_NONE,
        _del_parts          => Bric::FIELD_NONE,
        _et_grp_obj         => Bric::FIELD_NONE,
        _attr               => Bric::FIELD_NONE,
        _meta               => Bric::FIELD_NONE,
        _attr_obj           => Bric::FIELD_NONE,
        _att_obj            => Bric::FIELD_NONE,
    });
}

#==============================================================================#
# Interface Methods                    #
#======================================#

=head1 INTERFACE

=head2 Constructors

=over 4

=item $element = Bric::Biz::ElementType->new($init)

Will return a new asset type object with the optional initial state

Supported Keys:

=over 4

=item name

=item key_name

=item description

=item reference

=back

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub new {
    my ($class, $init) = @_;
    my $self = bless {}, ref $class || $class;
    $init->{_active} = 1;

    # Set reference unless explicitly set.
    $init->{reference} = $init->{reference} ? 1 : 0;
    $init->{type_id} = delete $init->{type__id}
      if exists $init->{type__id};
    $init->{et_grp_id} = delete $init->{et_grp__id}
      if exists $init->{et_grp__id};

    # Set the instance group ID.
    push @{$init->{grp_ids}}, INSTANCE_GROUP_ID;

    $self->SUPER::new($init);

    my $pkg = $self->get_biz_class;

    # If a package was passed in then find the autopopulated field names.
    my $i = 0;
    if ($pkg && UNIVERSAL::isa($pkg, 'Bric::Biz::Asset::Business::Media')) {
        foreach my $name ($pkg->autopopulated_fields) {
            my $key_name = lc $name;
            $key_name =~ y/a-z0-9/_/cs;
            my $atd = $self->new_field_type({
                key_name      => $key_name,
                name          => $name,
                description   => "Autopopulated $name field.",
                required      => 1,
                sql_type      => 'short',
                autopopulated => 1,
                widget_type   => 'text',
                length        => 32,
                place         => ++$i,
            });
        }
    }

    # Set the dirty bit for this new object.
    $self->_set__dirty(1);

    return $self;
}

#------------------------------------------------------------------------------#

=item $element = Bric::Biz::ElementType->lookup({id => $id})

=item $element = Bric::Biz::ElementType->lookup({key_name => $key_name})

Looks up and instantiates a new Bric::Biz::ElementType object based on the
Bric::Biz::ElementType object ID or name passed. If C<$id> or C<$key_name> is not
found in the database, C<lookup()> returns C<undef>.

B<Throws:>

=over 4

=item *

Too many Bric::Biz::ElementType objects found.

=back

B<Side Effects:> NONE

B<Notes:> NONE

=cut

sub lookup {
    my $pkg = shift;
    my $elem = $pkg->cache_lookup(@_);
    return $elem if $elem;

    $elem = $pkg->_do_list(@_);
    # We want @$cat to have only one value.
    throw_dp(error => 'Too many ' . __PACKAGE__ . ' objects found.')
      if @$elem > 1;
    return @$elem ? $elem->[0] : undef;
}

#------------------------------------------------------------------------------#

=item ($at_list || @at_list) = Bric::Biz::ElementType->list($param);

This will return a list of objects that match the criteria defined.

Supported Keys:

=over 4

=item id

Element ID. May use C<ANY> for a list of possible values.

=item name

The name of the asset type. Matched with case-insentive LIKE. May use C<ANY>
for a list of possible values.

=item key_name

The unique key name of the asset type. Matched with case insensitive LIKE. May
use C<ANY> for a list of possible values.

=item description

The description of the asset type. Matched with case-insentive LIKE. May use
C<ANY> for a list of possible values.

=item output_channel_id

The ID of an output channel. Returned will be all ElementType objects that
contain this output channel. May use C<ANY> for a list of possible values.

=item field_name

=item data_name

The name of an ElementType::Parts::FieldType (field type) object. Returned will be
all ElementType objects that reference this particular field type object. May
use C<ANY> for a list of possible values.

=item map_type_id

The map_type_id of a field type object. May use C<ANY> for a list of possible
values.

=item active

Set to 0 to return active and inactive asset types. 1, the default, returns
only active asset types.

=item type_id

match elements of a particular attype. May use C<ANY> for a list of possible
values.

=item top_level

set to 1 to return only top-level elements

=item media

match against a particular media asset type (att.media). May use C<ANY> for a
list of possible values.

=item site_id

match against the given site_id. May use C<ANY> for a list of possible values.

=back

B<Throws:>

NONE

B<Side Effects:>

NONE

B<Notes:>

NONE

=cut

sub list { _do_list(@_) }

#------------------------------------------------------------------------------#

=item ($at_list || @ats) = Bric::Biz::ElementType->list_ids($param)

This will return a list of objects that match the criteria defined. See the
C<list()> method for the allowed keys of the C<$param> hash reference.

B<Throws:>

NONE

B<Side Effects:>

NONE

B<Notes:>

NONE

=cut

sub list_ids { _do_list(@_, 1) }

#--------------------------------------#

=back

=head2 Destructors

=over 4

=item $self->DESTROY

Dummy method to prevent wasting time trying to AUTOLOAD DESTROY.

=cut

sub DESTROY {
    # This method should be here even if its empty so that we don't waste time
    # making Bricolage's autoload method try to find it.
}

#--------------------------------------#

=back

=head2 Public Class Methods

=over 4

=item $meths = Bric::Biz::ElementType->my_meths

=item (@meths || $meths_aref) = Bric::Biz::ElementType->my_meths(TRUE)

=item my (@meths || $meths_aref) = Bric::Biz::ElementType->my_meths(0, TRUE)

Returns an anonymous hash of introspection data for this object. If called
with a true argument, it will return an ordered list or anonymous array of
introspection data. If a second true argument is passed instead of a first,
then a list or anonymous array of introspection data will be returned for
properties that uniquely identify an object (excluding C<id>, which is
assumed).

Each hash key is the name of a property or attribute of the object. The value
for a hash key is another anonymous hash containing the following keys:

=over 4

=item name

The name of the property or attribute. Is the same as the hash key when an
anonymous hash is returned.

=item disp

The display name of the property or attribute.

=item get_meth

A reference to the method that will retrieve the value of the property or
attribute.

=item get_args

An anonymous array of arguments to pass to a call to get_meth in order to
retrieve the value of the property or attribute.

=item set_meth

A reference to the method that will set the value of the property or
attribute.

=item set_args

An anonymous array of arguments to pass to a call to set_meth in order to set
the value of the property or attribute.

=item type

The type of value the property or attribute contains. There are only three
types:

=over 4

=item short

=item date

=item blob

=back

=item len

If the value is a 'short' value, this hash key contains the length of the
field.

=item search

The property is searchable via the list() and list_ids() methods.

=item req

The property or attribute is required.

=item props

An anonymous hash of properties used to display the property or
attribute. Possible keys include:

=over 4

=item type

The display field type. Possible values are

=over 4

=item text

=item textarea

=item password

=item hidden

=item radio

=item checkbox

=item select

=back

=item length

The Length, in letters, to display a text or password field.

=item maxlength

The maximum length of the property or value - usually defined by the SQL DDL.

=back

=item rows

The number of rows to format in a textarea field.

=item cols

The number of columns to format in a textarea field.

=item vals

An anonymous hash of key/value pairs reprsenting the values and display names
to use in a select list.

=back

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

my $tmpl_archs;

sub my_meths {
    my ($pkg, $ord, $ident) = @_;

    unless ($tmpl_archs) {
    $tmpl_archs = [[BURNER_MASON, 'Mason']];
    push @$tmpl_archs, [BURNER_TEMPLATE, 'HTML::Template']
        if $Bric::Util::Burner::Template::VERSION;
    push @$tmpl_archs,  [BURNER_TT,'Template::Toolkit']
        if $Bric::Util::Burner::TemplateToolkit::VERSION;
    push @$tmpl_archs,  [BURNER_PHP,'PHP']
        if $Bric::Util::Burner::PHP::VERSION;
    }

    # Create 'em if we haven't got 'em.
    $METHS ||= {
          name        => {
                  name     => 'name',
                  get_meth => sub { shift->get_name(@_) },
                  get_args => [],
                  set_meth => sub { shift->set_name(@_) },
                  set_args => [],
                  disp     => 'Name',
                  search   => 1,
                  len      => 64,
                  req      => 1,
                  type     => 'short',
                  props    => { type      => 'text',
                        length    => 32,
                        maxlength => 64
                      }
                 },

              key_name    => {
                              name     => 'key_name',
                  get_meth => sub { shift->get_key_name(@_) },
                  get_args => [],
                  set_meth => sub { shift->set_key_name(@_) },
                  set_args => [],
                  disp     => 'Key Name',
                  search   => 1,
                  len      => 64,
                  req      => 1,
                  type     => 'short',
                  props    => {type      => 'text',
                                           length    => 32,
                                           maxlength => 64
                      }
                             },

          description => {
                  get_meth => sub { shift->get_description(@_) },
                  get_args => [],
                  set_meth => sub { shift->set_description(@_) },
                  set_args => [],
                  name     => 'description',
                  disp     => 'Description',
                  len      => 256,
                  req      => 0,
                  type     => 'short',
                  props    => { type => 'textarea',
                        cols => 40,
                        rows => 4
                      }
                 },
          burner      => {
                  get_meth => sub { shift->get_burner(@_) },
                  get_args => [],
                  set_meth => sub { shift->set_burner(@_) },
                  set_args => [],
                  name     => 'burner',
                  disp     => 'Burner',
                  len      => 80,
                  req      => 1,
                  type     => 'short',
                  props    => { type => 'select',
                        vals => $tmpl_archs,
                      }
                 },
          type_name      => {
                 name     => 'type_name',
                 get_meth => sub { shift->get_type_name(@_) },
                 get_args => [],
                 set_meth => sub { shift->set_type_name(@_) },
                 set_args => [],
                 disp     => 'Set',
                 len      => 64,
                 req      => 0,
                 type     => 'short',
                 props    => {   type       => 'text',
                         length     => 32,
                         maxlength => 64
                     }
                },
          active     => {
                 name     => 'active',
                 get_meth => sub { shift->is_active(@_) ? 1 : 0 },
                 get_args => [],
                 set_meth => sub { $_[1] ? shift->activate(@_)
                         : shift->deactivate(@_) },
                 set_args => [],
                 disp     => 'Active',
                 len      => 1,
                 req      => 1,
                 type     => 'short',
                 props    => { type => 'checkbox' }
                },
         };

    if ($ord) {
        return wantarray ? @{$METHS}{&ORD} : [@{$METHS}{&ORD}];
    } elsif ($ident) {
        return wantarray ? $METHS->{key_name} : [$METHS->{key_name}];
    } else {
        return $METHS;
    }
}


#--------------------------------------#

=back

=head2 Public Instance Methods

=over 4

=item $id = $element_type->get_id()

This will return the id for the database

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

#------------------------------------------------------------------------------#

=item $element_type = $element_type->set_name( $name )

This will set the name field for the asset type

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

#------------------------------------------------------------------------------#

=item $name = $element_type->get_name()

This will return the name field for the asset type

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

#------------------------------------------------------------------------------#

=item $element_type = $element_type->set_key_name($key_name)

This will set the unique key name field for the asset type

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

#------------------------------------------------------------------------------#

=item $name = $element_type->get_key_name()

This will return the unique key name field for the asset type

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

#------------------------------------------------------------------------------#

=item $element_type = $element_type->set_description($description)

this sets the description field

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

#------------------------------------------------------------------------------#

=item $description = $element_type->get_description()

This returns the description field

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

#------------------------------------------------------------------------------#

=item $element_type = $element_type->set_primary_oc_id( $primary_oc_id, $site )

This will set the primary output channel id field for the asset type

B<Throws:>

=over 4

=item *

No site parameter passed to Bric::Biz::ElementType-E<gt>set_primary_oc_id

=item *

No output channels associated with non top-level element types.

=back

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub set_primary_oc_id {
    my ( $self, $id, $site) = @_;

    throw_dp "No site parameter passed to " . __PACKAGE__ .
      "->set_primary_oc_id" unless $site;

    throw_dp "No output channels associated with non top-level element types"
      unless $self->get_top_level;

    $site = $site->get_id if ref $site;

    my $oc_site = $self->_get('_site_primary_oc_id');

    # If it is set and it is the same then don't bother
    return $self if ref $oc_site && defined $id && exists $oc_site->{$site}
      && $oc_site->{$site} == $id;

    $oc_site = {} unless ref $oc_site;
    $oc_site->{$site} = $id;
    $self->_set(['_site_primary_oc_id'], [$oc_site]);
    $self->_set__dirty(1);
    return $self;
}

#------------------------------------------------------------------------------#

=item $primary_oc_id = $element_type->get_primary_oc_id($site)

This will return the primary output channel id field for the asset type

B<Throws:>

=over 4

=item *

No site parameter passed to Bric::Biz::ElementType-E<gt>get_primary_oc_id.

=item *

No output channels associated with non top-level element types.

=back

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub get_primary_oc_id {
    my ($self, $site) = @_;

    throw_dp "No site parameter passed to " . __PACKAGE__ .
      "->get_primary_oc_id" unless $site;

    throw_dp "No output channels associated with non top-level element types"
      unless $self->get_top_level;

    $site = $site->get_id if ref $site;

    my $oc_site = $self->_get('_site_primary_oc_id');
    return $oc_site->{$site} if ref $oc_site && exists $oc_site->{$site};

    $oc_site = {} unless ref $oc_site;

    my $sel = prepare_c(qq {
        SELECT primary_oc__id
        FROM   element_type__site
        WHERE  element_type__id = ? AND
               site__id    = ?
    }, undef, DEBUG);

    execute($sel, $self->get_id, $site);

    my $ret = fetch($sel);
    finish($sel);
    return unless $ret;

    my $dirty = $self->_get__dirty();
    $oc_site->{$site} = $ret->[0];
    $self->_set(['_site_primary_oc_id'],[$oc_site]);
    $self->_set__dirty($dirty);
    return $ret->[0];
}

#------------------------------------------------------------------------------#

=item $name = $at->get_type_name

Get the type name of the asset type.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

#------------------------------------------------------------------------------#

=item $burner = $at->get_burner

Get the burner associated with the asset type.  Possible values are
the constants BURNER_MASON and BURNER_TEMPLATE defined in this package.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

#------------------------------------------------------------------------------#

=item $at->set_burner(Bric::Biz::ElementType::BURNER_MASON);

Get the burner associated with the asset type.  Possible values are
the constants BURNER_MASON and BURNER_TEMPLATE defined in this package.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut


sub get_type_name {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    return $att_obj->get_name;
}

#------------------------------------------------------------------------------#

=item $desc = $at->get_type_description

Get the type description of the asset type.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

sub get_type_description {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    return $att_obj->get_description;
}

#------------------------------------------------------------------------------#

=item ($at || undef) = $at->get_top_level

Return whether this is a top level story or not.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

sub get_top_level {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    return $att_obj->get_top_level;
}

#------------------------------------------------------------------------------#

=item ($at || undef) = $at->get_paginated

Return whether this asset type should produce a paginated asset or not.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

sub get_paginated {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    return $att_obj->get_paginated;
}

#------------------------------------------------------------------------------#

=item ($at || undef) = $at->is_related_media

Return whether this asset type can have related media objects.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

sub is_related_media {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    return $att_obj->get_related_media;
}

=item ($at || undef) = $at->is_related_story

Return whether this asset type can have related story objects.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

sub is_related_story {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    return $att_obj->get_related_story;
}

#------------------------------------------------------------------------------#

=item ($at || undef) = $at->is_media()

=item $at = $at->set_media()

=item $at = $at->clear_media()

Mark this Asset Type as representing a media object or a story object.  Media
objects do not support all the options that story objects to like nested 
containers or references, but they include options that story doesnt like 
autopopulated fields.

The 'is_media' method returns true if this is a media object and false 
otherwise. The 'set_media' method marks this as a media object.  It does not
take any arguments, and always sets the media flag to true, so you cant do this:

$at->set_media(0)

and expect to set the media flag to false.  To unset the media flag (set it to
false) use the 'clear_media' method.

B<Throws:>

NONE

B<Side Effects:>

NONE

B<Notes:>

NONE

=cut

sub is_media {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    return $att_obj->get_media ? $self : undef;
}

sub set_media {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    $att_obj->set_media(1);

    return $self;
}

sub clear_media {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    $att_obj->set_media(0);

    return $self;
}

#------------------------------------------------------------------------------#

=item $at->get_biz_class()

=item $at->get_biz_class_id()

=item $at->set_biz_class('class' => '' || 'id' => '');

The methods 'get_biz_class' and 'get_biz_class_id' get the business class name
or the business class ID respectively from the class table.

The 'set_biz_class' method sets the business class for this asset type given
either a class name or an ID from the class table.

This value represents the kind of bussiness object this asset type will
represent. There are just two main kinds, story and media objects. However
media objects have many subclasses, one for each type of supported media
(image, audio, video, etc) increasing the number of package names this value
could be set to.

B<Throws:>

NONE

B<Side Effects:>

NONE

B<Notes:>

NONE

=cut

sub get_biz_class {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj or return;
    my $class = Bric::Util::Class->lookup({'id' => $att_obj->get_biz_class_id})
      or return;
    return $class->get_pkg_name;
}

sub get_biz_class_id {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj or return;
    return $att_obj->get_biz_class_id;
}

sub get_type__id   { shift->get_type_id       }
sub set_type__id   { shift->set_type_id(@_)   }
sub get_at_grp__id { shift->get_et_grp_id     }
sub set_at_grp__id { shift->set_et_grp_id(@_) }

#------------------------------------------------------------------------------#

=item ($at || undef) = $at->get_reference

=item $at = $at->set_reference(1 || 0)

Return whether this asset type references other data.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

sub get_reference {
    my $self = shift;

    return $self->_get('reference') ? $self : undef;
}

sub set_reference {
    my $self = shift;
    my ($bool) = @_;

    $self->_set(['reference'], [$bool ? 1 : 0]);

    $self->_set__dirty(1);

    return $self;
}

#------------------------------------------------------------------------------#

=item ($at || undef) = $at->get_fixed_url

Return whether this asset type should produce a fixed url asset or not.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

sub get_fixed_url {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return unless $att_obj;

    return $att_obj->get_fixed_url;
}

#------------------------------------------------------------------------------#

=item $at_type = $at->get_at_type

Return the at_type object associated with this element type.

B<Throws:>
NONE

B<Side Effects:>
NONE

B<Notes:>
NONE

=cut

sub get_at_type {
    my $self = shift;
    my $att_obj = $self->_get_at_type_obj;

    return $att_obj;
}

#------------------------------------------------------------------------------#

=item $val = $element_type->set_attr($name, $value);

=item $val = $element_type->get_attr($name);

=item $val = $element_type->del_attr($name);

Get/Set/Delete attributes on this asset type.

B<Throws:>

NONE

B<Side Effects:>

NONE

B<Notes:>

NONE

=cut


sub set_attr {
    my $self = shift;
    my ($name, $val) = @_;
    my $attr     = $self->_get('_attr');
    my $attr_obj = $self->_get_attr_obj;

    # If we have an attr object, then populate it
    if ($attr_obj) {
    $attr_obj->set_attr({'name'     => $name,
                 'sql_type' => 'short',
                 'value'    => $val});
    }
    # Otherwise,cache this value until save.
    else {
    $attr->{$name} = $val;
    $self->_set(['_attr'], [$attr]);
    }

    $self->_set__dirty(1);

    return $val;
}

sub get_attr {
    my $self = shift;
    my ($name) = @_;
    my $attr     = $self->_get('_attr');
    my $attr_obj = $self->_get_attr_obj;

    # If we aren't saved yet, return anything we have cached.
    return $attr->{$name} unless $self->get_id;

    return $attr_obj->get_attr({'name' => $name});
}

sub del_attr {
    my $self = shift;
    my ($name) = @_;
    my $attr     = $self->_get('_attr');
    my $attr_obj = $self->_get_attr_obj;

    # If we aren't saved yet, delete from the cache.
    delete $attr->{$name} unless $self->get_id;

    return $attr_obj->delete_attr({'name' => $name});
}

sub all_attr {
    my $self = shift;
    my $attr     = $self->_get('_attr');
    my $attr_obj = $self->_get_attr_obj;

    # If we aren't saved yet, return the cache
    return $attr unless $self->get_id;

    # HACK: This identifies attr names begining with a '_' as private and will 
    # not return them.  This is being done instead of using subsystems because
    # we are using subsystems to keep ElementTypes unique from each other.
    my $ah = $attr_obj->get_attr_hash();

    # Evil delete on a hash slice based on values returned by grep...
    delete(@{$ah}{ grep(substr($_,0,1) eq '_', keys %$ah) });

    return $ah
}

#------------------------------------------------------------------------------#

=item $val = $element_type->set_meta($name, $field, $value);

=item $val = $element_type->get_meta($name, $field);

=item $val = $element_type->get_meta($name);

Get/Set attribute metadata on this asset type.  Calling the 'get_meta' method
without '$field' returns all metadata names and values as a hash.

B<Throws:>

NONE

B<Side Effects:>

NONE

B<Notes:>

NONE

=cut

sub set_meta {
    my $self = shift;
    my ($name, $field, $val) = @_;
    my $attr_obj = $self->_get_attr_obj;
    my $meta     = $self->_get('_meta');

    if ($attr_obj) {
    $attr_obj->add_meta({'name'  => $name,
                 'field' => $field,
                 'value' => $val});
    } else {
    $meta->{$name}->{$field} = $val;
    
    $self->_set(['_meta'], [$meta]);
    }

    $self->_set__dirty(1);

    return $val;
}

sub get_meta {
    my $self = shift;
    my ($name, $field) = @_;
    my $attr_obj = $self->_get_attr_obj;
    my $meta     = $self->_get('_meta');

    unless ($attr_obj) {
    if (defined $field) {
        return $meta->{$name}->{$field};
    } else {
        return $meta->{$name};
    }
    }

    if (defined $field) {
    return $attr_obj->get_meta({'name'  => $name,
                    'field' => $field});
    } else {
    my $meta = $attr_obj->get_meta({'name'  => $name});

    return { map { $_ => $meta->{$_}->{'value'} } keys %$meta };
    }
}

#------------------------------------------------------------------------------#

=item ($oc_list || @oc_list) = $element_type->get_output_channels;

=item ($oc_list || @oc_list) = $element_type->get_output_channels(@oc_ids);

This returns a list of output channels that have been associated with this
asset type. If C<@oc_ids> is passed, then only the output channels with those
IDs are returned, if they're associated with this asset type.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> The objects returned will be Bric::Biz::OutputChannel::Element
objects, and these objects contain extra information relevant to the
assocation between each output channel and this element object.

=cut

sub get_output_channels { $get_oc_coll->(shift)->get_objs(@_) }

#------------------------------------------------------------------------------#

=item my $oce = $element_type->add_output_channel($oc)

=item my $oce = $element_type->add_output_channel($oc_id)

Adds an output channel to this element object and returns the resulting
Bric::Biz::OutputChannel::Element object. Can pass in either an output channel
object or an output channel ID.

B<Throws:> NONE.

B<Side Effects:> If a Bric::Biz::OutputChannel object is passed in as the
first argument, it will be converted into a Bric::Biz::OutputChannel::Element
object.

B<Notes:> NONE.

=cut

sub add_output_channel {
    my ($self, $oc) = @_;
    my $oc_coll = $get_oc_coll->($self);
    $oc_coll->new_obj({ (ref $oc ? 'oc' : 'oc_id') => $oc,
                        element_type_id => $self->_get('id') });
}

#------------------------------------------------------------------------------#

=item $element_type = $element_type->add_output_channels([$output_channels])

This accepts an array reference of output channel objects to be associated
with this asset type.

B<Throws:> NONE.

B<Side Effects:> Any Bric::Biz::OutputChannel objects passed in will be
converted into Bric::Biz::OutputChannel::Element objects.

B<Notes:> NONE.

=cut

sub add_output_channels {
    my ($self, $ocs) = @_;
    $self->add_output_channel($_) for @$ocs;
    return $self;
}

#------------------------------------------------------------------------------#

=item $element_type = $element_type->delete_output_channels([$output_channels])

This takes an array reference of output channels and removes their association
from the object.

B<Throws:>

=over 4

=item *

Cannot delete a primary output channel.

=back

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub delete_output_channels {
    my ($self, $ocs) = @_;
    my $oc_coll = $get_oc_coll->($self);
    no warnings 'uninitialized';
    foreach my $oc (@$ocs) {
        $oc = Bric::Biz::OutputChannel::Element->lookup({ id => $oc })
          unless ref $oc;
        throw_dp "Cannot delete a primary output channel"
          if $self->get_primary_oc_id($oc->get_site_id) == $oc->get_id;
    }

    $oc_coll->del_objs(@$ocs);
    return $self;
}

#------------------------------------------------------------------------------#

=item ($site_list || @site_list) = $element_type->get_sites;

=item ($site_list || @site_list) = $element_type->get_sites(@site_ids);

This returns a list of sites that have been associated with this
asset type. If C<@site_ids> is passed, then only the sites with those
IDs are returned, if they're associated with this asset type.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> The objects returned will be Bric::Biz::Site
objects, and these objects contain extra information relevant to the
assocation between each output channel and this element object.

=cut

sub get_sites { $get_site_coll->(shift)->get_objs(@_) }

#------------------------------------------------------------------------------#

=item my $site = $element_type->add_site($site)

=item my $site = $element_type->add_site($site_id)

Adds a site to this element object and returns the resulting
Bric::Biz::Site object. Can pass in either an site object or a site ID.

B<Throws:>

=over 4

=item *

You can only add sites to top level objects

=item *

Cannot add sites to non top-level element types.

=item *

No such site.

=back

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub add_site {
    my ($self, $site) = @_;

    throw_dp "Cannot add sites to non top-level element types"
      unless $self->get_top_level;

    my $site_coll = $get_site_coll->($self);
    $site = Bric::Biz::Site->lookup({ id =>  $site}) unless ref $site;

    throw_dp "No such site" unless ref $site;

    $site_coll->add_new_objs( $site );
    return $site;
}
#------------------------------------------------------------------------------#

=item my $site = $element_type->add_sites([$site])

=item my $site = $element_type->add_sites([$site_id])

Adds a site to this element object and returns the Bric::Biz::ElementType
object. Can pass in multiple site objects or site IDs.

B<Throws:>

=over 4

=item *

You can only add sites to top level objects

=item *

Couldn't find site

=back

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub add_sites {
    my ($self, $sites) = @_;
    $self->add_site($_) for @$sites;
}

#------------------------------------------------------------------------------#

=item $element_type = $element_type->remove_sites([$sites])

This takes an array reference of sites and removes their association from the
object.

B<Throws:>

=over 4

=item *

Cannot remove last site from an element type.

=back

B<Side Effects:> Also disassociates any output channels for the site that are
associated with this element.

B<Notes:> NONE.

=cut

sub remove_sites {
    my ($self, $sites) = @_;
    my $site_coll = $get_site_coll->($self);
    throw_dp "Cannot remove last site from an element type"
      if @{$site_coll->get_objs} < 2;

    #here we need to remove all corresponding output channels
    #for this site

    my $oces = $self->get_output_channels();
    my @delete_oc;
    for my $site (@$sites) {
        my $site_id = (ref($site) ? $site->get_id : $site);
        foreach my $oce (@$oces) {
            if ($site_id == $oce->get_site_id) {
                push @delete_oc, $oce;
                $self->set_primary_oc_id(undef, $oce->get_site_id)
                  if ($self->get_primary_oc_id($site_id) == $oce->get_id);

            }
        }
    }
    $self->delete_output_channels(\@delete_oc);
    $site_coll->del_objs(@$sites);

    return $self;
}

#------------------------------------------------------------------------------#

=item get_field_types()

=item get_data()

  my @field_types = $element_type->get_field_types;
  my $field_type  = $element_type->get_field_types($key_name);
     @field_types = $element_type->get_data;
     $field_type  = $element_type->get_data($key_name);

Returns a list or array reference of the field types that the element type
contains. Pass in a key name to get back a single field type.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> C<get_data()> is the deprecated form of this method.

=cut

sub get_field_types {
    my ($self, $key_name) = @_;
    my $parts     = $self->_get_parts();
    my $new_parts = $self->_get('_new_parts');
    my @all = values %$parts;

    # Include the yet to be added parts.
    while (my ($id, $obj) = each %$new_parts) {
        push @all, $id == -1 ? @$obj : $obj;
    }

    return first { $_->get_key_name eq $key_name } @all
        if $key_name;

    @all = map  {         $_->[1]         }
           sort {   $a->[0] <=> $b->[0]   }
           map  { [ $_->get_place => $_ ] }
           @all;
    return wantarray ? @all : \@all;
}

sub get_data { shift->get_field_types(@_) }

#------------------------------------------------------------------------------#

=item $element_type->add_field_type(@field_types);

  $element_type->add_field_types(@field_types);
  $element_type->add_field_types(\@field_types);
  $element_type->add_data(@field_types);
  $element_type->add_data(\@field_types);

This takes a list of field typess and associates them with the element type
object.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> C<add_data()> is the deprecated form of this method.

=cut

sub add_field_types {
    my $self = shift;
    my $field_types = ref $_[0] eq 'ARRAY' ? shift : \@_;
    my $parts = $self->_get_parts;
    my ($new_parts, $del_parts) = $self->_get(qw(_new_parts _del_parts));

    foreach my $p (@$field_types) {
        throw_gen 'Must pass field type object to add_field_types()'
          unless ref $p;

        # Get the ID if we were passed an object.
        my $p_id = $p->get_id;

        # Skip adding this part if it already exists.
        next if exists $parts->{$p_id};

        # Add this to the parts list.
        $new_parts->{$p_id} = $p;

        # Remove this value from the deletion list if its there.
        delete $del_parts->{$p_id};
    }

    # Update $self's new and deleted parts lists.
    $self->_set(['_del_parts'] => [$del_parts]);

    # Set the dirty bit since something has changed.
    $self->_set__dirty(1);

    return $self;
}

sub add_data { shift->add_field_types(@_) }

#------------------------------------------------------------------------------#

=item $element_type->new_field_type()

  my $field_type = $element_type->new_field_type(\%params);
     $field_type = $element_type->new_data(\%params);

Adds a new field type to the element type, creating a new
Bric::Biz::ElementType::Parts::FieldType object. See
L<Bric::Biz::ElementType::Parts::FieldType|Bric::Biz::ElementType::Parts::FieldType> for a
list of the parameters to its C<new()> method for the parameters that can be
specified in the parameters hash reference passsed to C<new_field_type()>.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub new_field_type {
    my ($self, $param) = @_;
    my ($new_parts) = $self->_get('_new_parts');

    # Create the new field type.
    my $part = Bric::Biz::ElementType::Parts::FieldType->new($param);

    # Add all new values to a special array of new parts until they can be
    # saved and given an ID.
    push @{$new_parts->{-1}}, $part;

    # Update $self's new parts lists.
    $self->_set(['_new_parts'] => [$new_parts]);

    # Set the dirty bit since something has changed.
    $self->_set__dirty(1);

    return $part;
}

sub new_data { shift->new_field_type(@_) }

#------------------------------------------------------------------------------#

=item $element_type->copy_field_type()

  my $field_type = $element_type->copy_field_type(\%params);
     $field_type = $element_type->copy_data(\%params);

Copies the definition for a field type from another eelement type. The
parameters expected in the hash reference argument are:

=over 4

=item field_type

=item field_obj

The field type object to copy into this element type. Required unless
C<element_type> and C<field_key_name> have been specified.

=item element_type

=item at

An existing element type object from which to extract a field to copy.
Required unless C<field_type> has been specified.

=item field_key_name

=item field_name

The key name of a field associated with the element type passed via the
C<element_type> parameter. Required unless C<field_type> has been specified.

=back

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> C<copy_data()> is the deprecated form of this method.

=cut

sub copy_field_type {
    my ($self, $param)   = @_;
    my $new_parts        = $self->_get('_new_parts');
    my $field_type       = $param->{field_type} || $param->{field_obj};

    unless ($field_type) {
        my $element_type = $param->{element_type} || $param->{at};
        throw_gen 'No field_type or element_type parameter'
            unless $element_type;
        my $key_name = $param->{field_key_name} || $param->{field_name};
        throw_gen 'No field_key_name parameter' unless defined $key_name;
        $field_type = $element_type->get_field_types($key_name);
    }

    return $self->add_field_types($field_type->copy($self->get_id));
}

sub copy_data { shift->copy_field_type(@_) }

#------------------------------------------------------------------------------#

=item $element_type->del_field_types()

  $element_type->del_field_types(@field_types);
  $element_type->del_field_types(\@field_types);
  $element_type->del_data(@field_types);
  $element_type->del_data(\@field_types);

Removes the specified field types from the element type.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> C<del_data()> is the deprecated form of this method.

=cut

sub del_field_types {
    my $self        = shift;
    my $field_types = ref $_[0] eq 'ARRAY' ? shift : \@_;
    my $parts       = $self->_get_parts;

    my ($new_parts, $del_parts) = $self->_get(qw(_new_parts _del_parts));

    for my $p (@$field_types) {
        throw_gen 'Must pass field type objects to del_field_types()'
            unless ref $p;

        # Get the ID if we were passed an object.
        my $p_id = $p->get_id;

        # Delete this part from the list and put it on the deletion list.
        if (delete $parts->{$p_id}) {
            # Add the object as a value.
            $del_parts->{$p_id} = $p;
        }

        # Remove this value from the addition list if it's there.
        delete $new_parts->{$p_id};
    }

    # Update $self's new and deleted parts lists.
    $self->_set(
        [qw(_parts _new_parts _del_parts)]
        => [$parts, $new_parts, $del_parts]
    );

    # Set the dirty bit since something has changed.
    return $self->_set__dirty(1);
}

sub del_data { shift->del_field_types(@_) }

#------------------------------------------------------------------------------#

=item $element_type->add_containers()

  $element_type->add_containers(@element_types);
  $element_type->add_containers(\@element_types);

Add element types to the element type as subelement types.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub add_containers {
    my $self = shift;
    my $ets  = ref $_[0] eq 'ARRAY' ? shift : \@_;
    my $grp = $self->_get_asset_type_grp;

    # Construct the proper array to pass to 'add_members'
    my @mem = map {
        ref $_ ? {obj => $_ }
               : {id  => $_, package => __PACKAGE__ }
    } @$ets;

    return unless $grp->add_members(\@mem);
    return $self;
}

#------------------------------------------------------------------------------#

=item $element_type->get_containers()

  my @element_types      = $element_type->get_containers;
  my $element_types_aref = $element_type->get_containers;
  my $element_type       = $element_type->get_containers($key_name);

Returns all subelement element types.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub get_containers {
    my ($self, $key_name) = @_;

    my $grp = $self->_get_asset_type_grp;
    return $grp->get_objects unless defined $key_name;

    return first { $_->get_key_name eq $key_name } $grp->get_objects;
}

#------------------------------------------------------------------------------#

=item $element_type->del_containers()

  $element_type->del_containers(@element_types);
  $element_type->del_containers(\@element_types);

Remove subelement element types from the element type. The subelement element
types will not be deactivated, just disassociated with the parent element
type.

B<Throws:>

NONE

B<Side Effects:>

NONE

B<Notes:>

NONE

=cut

sub del_containers {
    my $self = shift;
    my $ets  = ref $_[0] eq 'ARRAY' ? shift : \@_;
    my $grp  = $self->_get_asset_type_grp;

    # Construct the proper array to pass to 'add_members'
    my @mem = map {
        ref $_ ? { obj => $_ }
               : { id  => $_, package => __PACKAGE__ }
    } @$ets;

    return unless $grp->delete_members(\@mem);
    return $self;
}

#------------------------------------------------------------------------------#

=item $element_type->is_active()

Return true if the element type is active, and false if it is not.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub is_active {
    my $self = shift;
    return $self->_get('_active') ? $self : undef;
}

#------------------------------------------------------------------------------#

=item $element_type = $element_type->activate()

Activates the element type.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub activate { shift->_set(['_active'] => [1]) }

#------------------------------------------------------------------------------#

=item $element_type->deactivate()

Deactivates the element type.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub deactivate { shift->_set(['_active'] => [0]) }

#------------------------------------------------------------------------------#

=item $element_type->save()

Saves changes to the element type, including its subelement element type and
field type associatesions, to the database.

B<Throws:>

NONE

B<Side Effects:>

NONE

B<Notes:>

NONE

=cut

sub save {
    my $self = shift;

    my ($id, $oc_coll, $site_coll, $primary_oc_site)
        = $self->_get(qw(id _oc_coll _site_coll _site_primary_oc_id));

    # Save the group information.
    $self->_get_asset_type_grp->save;

    if ($id) {
        # Save the parts and the output channels.
        $oc_coll->save($id) if $oc_coll;

        # Save the sites if object has an id
        $site_coll->save($id, $primary_oc_site) if $site_coll;
    }

    # Don't do anything else unless the dirty bit is set.
    return $self unless $self->_get__dirty;

    unless ($self->is_active) {
        # Check to see if this AT is reference anywhere. If not, delete it.
        unless ($self->_is_referenced) {
            $self->$remove;
            return $self;
        }
    }

    # First save the main object information
    if ($id) {
        $self->_update_asset_type;
    } else {
        $self->_insert_asset_type;
        $id = $self->_get('id');

        # Save the sites.
        $site_coll->save($id, $primary_oc_site) if $site_coll;

        # Save the output channels.
        $oc_coll->save($id) if $oc_coll;
    }

    # Save the mapping of primary oc per site
    if ($primary_oc_site and %$primary_oc_site) {
        my $update = prepare_c(qq{
            UPDATE element_type__site
            SET    primary_oc__id   = ?
            WHERE  element_type__id = ? AND
                   site__id         = ?
        },undef, DEBUG);
        foreach my $site_id (keys %$primary_oc_site) {
            my $oc_id = delete $primary_oc_site->{$site_id} or next;
            execute($update, $oc_id, $id, $site_id);
        }
    }

    # Save the attribute information.
    $self->_save_attr;

    # Save the parts.
    $self->_sync_parts;


    # Call our parents save method.
    return $self->SUPER::save;
}

#==============================================================================#

=back

=head1 PRIVATE


=head2 Private Class Methods

=over 4

=item _do_list

called from list and list ids this will query the db and return either
ids or objects

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub _do_list {
    my ($pkg, $params, $ids) = @_;
    my $tables = "$table a, $mem_table m, $map_table c";
    my @wheres = ('a.id = c.object_id', 'c.member__id = m.id',
                  "m.active = '1'");
    my ($top, @params);

    # Set up the active parameter.
    if (exists $params->{active}) {
        my $val = delete $params->{active};
        # Only set the active flag if they've passed a specific value.
        if (defined $val) {
            push @wheres, "a.active = ?";
            push @params, $val ? 1 : 0;
        }
    } elsif (! exists $params->{id}) {
        push @wheres, "a.active = ?";
        push @params, 1;
    } else {
        # Do nothing -- let ID return even deactivated element types.
    }

    # Set up paramters based on an ElementType::Data name or a map type ID.
    if (exists $params->{data_name} or exists $params->{map_type_id}
          or exists $params->{map_type__id})
    {
        # Add the field_type table.
        $tables .= ', field_type d';
        push @wheres, 'd.element_type__id = a.id';
        if (exists $params->{data_name}) {
            push @wheres, any_where(
                delete $params->{data_name},
                'LOWER(d.key_name) LIKE LOWER(?)',
                \@params
            );
        }
        if (exists $params->{map_type_id} or exists $params->{map_type__id}) {
            push @wheres, any_where(
                ( delete $params->{map_type_id}
                  || delete $params->{map_type__id} ),
                'd.map_type__id = ?',
                \@params
            );
        }
    }

    # Set up parameters based on asset types.
    if (exists $params->{top_level} or exists $params->{media}) {
        $tables .= ', at_type att';
        push @wheres, 'att.id = a.type__id';
        if (exists $params->{top_level}) {
            push @wheres, 'att.top_level = ?';
            push @params, $top = delete $params->{top_level} ? 1 : 0;
        }
        if (exists $params->{media}) {
            push @wheres, 'att.media = ?';
            push @params, delete $params->{media} ? 1 : 0;
        }
    }

    # Set up the rest of the parameters.
    while (my ($k, $v) = each %$params) {
        if ($k eq 'output_channel_id' || $k eq 'output_channel') {
            $tables .= ', element_type__output_channel ao';
            push @wheres, 'ao.element_type__id = a.id';
            push @wheres, any_where($v, 'ao.output_channel__id = ?', \@params);
        } elsif ($k eq 'type_id' || $k eq 'type__id') {
            push @wheres, any_where($v, "a.type__id = ?", \@params);
        } elsif ($k eq 'id') {
            push @wheres, any_where($v, "a.$k = ?", \@params);
        } elsif ($k eq 'grp_id') {
            # Fancy-schmancy second join.
            $tables .= ", $mem_table m2, $map_table c2";
            push @wheres, (
                'a.id = c2.object_id',
                'c2.member__id = m2.id',
                "m2.active = '1'"
            );
            push @wheres, any_where($v, 'm2.grp__id = ?', \@params);
        } elsif ($k eq 'site_id') {
            $tables .= ", element_type__site es";
            push @wheres, 'es.element_type__id = a.id', "es.active = '1'";
            push @wheres, any_where($v, 'es.site__id = ?', \@params);
        } else {
            # The "name" and "description" properties.
            push @wheres, any_where($v, "LOWER(a.$k) LIKE LOWER(?)", \@params);
        }
    }

    # Assemble and prepare the query.
    my $where = join ' AND ', @wheres;
    my ($qry_cols, $order) = $ids ? (\'DISTINCT a.id', 'a.id') :
      (\$sel_cols, 'a.name, a.id');
    my $sel = prepare_c(qq{
        SELECT $$qry_cols
        FROM   $tables
        WHERE  $where
        ORDER BY $order
    }, undef);

    # Just return the IDs, if they're what's wanted.
    return wantarray ? @{col_aref($sel, @params)} : col_aref($sel, @params)
      if $ids;

    execute($sel, @params);
    my (@d, @elems, $grp_ids);
    bind_columns($sel, \@d[0..$#sel_props]);
    $pkg = ref $pkg || $pkg;
    my $last = -1;
    while (fetch($sel)) {
        if ($d[0] != $last) {
            $last = $d[0];
            # Create a new element type object.
            my $self = bless {}, $pkg;
            $self->SUPER::new;
            $grp_ids = $d[$#d] = [$d[$#d]];
            $self->_set(\@sel_props, \@d);
            # Add the attribute object.
            # HACK: Get rid of this object!
            $self->_set( ['_attr_obj'],
                         [ Bric::Util::Attribute::ElementType->new
                           ({ object_id => $d[0],
                              subsys => "id_$d[0]" })
                         ]
                       );
            $self->_set__dirty; # Disable the dirty flag.
            push @elems, $self->cache_me;
        } else {
            # Append the ID.
            push @$grp_ids, $d[$#d];
        }
    }

    # Multisite element types are all the top-level for the site,
    # plus all non top-level element types.
    if($params->{site_id} && ! $top) {
        delete $params->{site_id};
        $params->{top_level} = 0;
        push @elems, _do_list($pkg, $params);

    }

    return wantarray ? @elems : \@elems;
}

##############################################################################

=back

=head2 Private Instance Methods

These need documenting.

=over 4

=item _is_referenced

=cut

sub _is_referenced {
    my $self = shift;
    my $rows;

    # Make sure this isn't referenced from an asset.
    my $table = $self->is_media ? 'media' : 'story';
    my $sql  = "SELECT COUNT(*) FROM $table WHERE element_type__id = ?";
    my $sth  = prepare_c($sql, undef);
    execute($sth, $self->get_id);
    bind_columns($sth, \$rows);
    fetch($sth);
    finish($sth);

    return 1 if $rows;

    # Make sure this isn't used by another asset type.
    $sql = 'SELECT COUNT(*) '.
           'FROM element_type_member atm, member m, element_type at '.
       'WHERE atm.object_id = ? AND '.
                  'm.id         = atm.member__id AND '.
                  'm.grp__id    = at.et_grp__id';

    $sth  = prepare_c($sql, undef);
    execute($sth, $self->get_id);
    bind_columns($sth, \$rows);
    fetch($sth);
    finish($sth);

    return 1 if $rows;

    # Make sure this isn't referenced from a template.
    $sql  = "SELECT COUNT(*) FROM formatting WHERE element_type__id = ?";
    $sth  = prepare_c($sql, undef);
    execute($sth, $self->get_id);
    bind_columns($sth, \$rows);
    fetch($sth);
    finish($sth);

    return 1 if $rows;

    return 0;
}

#------------------------------------------------------------------------------#

=item $element_type->$remove

Removes this object completely from the DB. Returns 1 if active or undef
otherwise

B<Throws:>

NONE

B<Side Effects:>

NONE

B<Notes:>

NONE

=cut

$remove = sub {
    my $self = shift;
    my $id = $self->get_id or return;
    my $sth = prepare_c("DELETE FROM $table WHERE id = ?",
                        undef);
    execute($sth, $id);
    return $self;
};

=item _get_attr_obj

=cut

sub _get_attr_obj {
    my $self = shift;
    my $attr_obj = $self->_get('_attr_obj');
    my $id = $self->get_id;

    unless ($attr_obj || not defined($id)) {
    $attr_obj = Bric::Util::Attribute::ElementType->new(
                     {'object_id' => $id,
                      'subsys'    => "id_$id"});
    $self->_set(['_attr_obj'], [$attr_obj]);
    }

    return $attr_obj;
}

=item _get_at_type_obj

=cut

sub _get_at_type_obj {
    my $self = shift;
    my $att_id  = $self->get_type_id;
    my $att_obj = $self->_get('_att_obj');

    return $att_obj if $att_obj;

    if ($att_id) {
    $att_obj = Bric::Biz::ATType->lookup({'id' => $att_id});
    $self->_set(['_att_obj'], [$att_obj]);
    }

    return $att_obj;
}

=item _save_attr

=cut

sub _save_attr {
    my $self = shift;
    my ($attr, $meta, $a_obj) = $self->_get('_attr', '_meta', '_attr_obj');
    my $id   = $self->get_id;

    unless ($a_obj) {
        $a_obj = Bric::Util::Attribute::ElementType->new({
            object_id => $id,
            subsys    => "id_$id"
        });
        $self->_set(['_attr_obj'], [$a_obj]);

        while (my ($k,$v) = each %$attr) {
            $a_obj->set_attr({
                name     => $k,
                sql_type => 'short',
                value    => $v
            });
        }

        foreach my $k (keys %$meta) {
            while (my ($f, $v) = each %{$meta->{$k}}) {
                $a_obj->add_meta({
                    name  => $k,
                    field => $f,
                    value => $v
                });
            }
        }
    }

    $a_obj->save;
}

=item _get_asset_type_grp

=cut

sub _get_asset_type_grp {
    my $self = shift;
    my $atg_id  = $self->get_et_grp_id;
    my $atg_obj = $self->_get('_et_grp_obj');

    return $atg_obj if $atg_obj;

    if ($atg_id) {
        $atg_obj = Bric::Util::Grp::SubelementType->lookup({'id' => $atg_id});
        $self->_set(['_et_grp_obj'], [$atg_obj]);
    } else {
        $atg_obj = Bric::Util::Grp::SubelementType->new({
            name => 'ElementType Group'
        });
        $atg_obj->save;

        $self->_set(['et_grp_id',     '_et_grp_obj'],
                    [$atg_obj->get_id, $atg_obj]);
    }

    return $atg_obj;
}

=item _sync_parts

=cut

sub _sync_parts {
    my $self = shift;
    my $parts = $self->_get_parts();
    my ($id, $new_parts, $del_parts)
        = $self->_get(qw(id _new_parts _del_parts));

    # Pull off the newly created parts.
    my $created = delete $new_parts->{-1};

    # Now that we know we have an ID for $self, set element type ID for
    for my $p_obj (@$created) {
        $p_obj->set_element_type_id($id);

        # Save the parts object.
        $p_obj->save;

        # Add it to the current parts list.
        $parts->{$p_obj->get_id} = $p_obj;
    }

    # Add parts that already existed when they were added.
    foreach my $p_id (keys %$new_parts) {
        # Delete this from the new list and grab the object.
        my $p_obj = delete $new_parts->{$p_id};

        # Save the parts object.
        $p_obj->save;

        # Add it to the current parts list.
        $parts->{$p_id} = $p_obj;
    }

    # Deactivate removed parts.
    for my $p_id (keys %$del_parts) {
        # Delete this from the deletion list and grab the object.
        my $p_obj = delete $del_parts->{$p_id};

        # This needs to happen for deleted parts.
        $p_obj->deactivate;
        $p_obj->set_required(0);
        $p_obj->save;
    }
    return $self;
}

#------------------------------------------------------------------------------#

=item $element_type->_update_asset_type()

Update values in the element_type table.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub _update_asset_type {
    my $self = shift;

    my $sql = "UPDATE $table".
              ' SET '.join(',', map {"$_=?"} @cols).' WHERE id=?';


    my $sth = prepare_c($sql, undef);
    execute($sth, $self->_get(@props), $self->get_id);

    return $self;
}

#------------------------------------------------------------------------------#

=item $element_type->_insert_asset_type()

Insert new values into the element_type table.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub _insert_asset_type {
    my $self = shift;
    my $nextval = next_key($table);

    # Create the insert statement.
    my $sql = "INSERT INTO $table (".join(', ', 'id', @cols).') '.
              "VALUES ($nextval,".join(',', ('?') x @cols).')';

    my $sth = prepare_c($sql, undef);
    execute($sth, $self->_get(@props));

    # Set the ID of this object.
    $self->_set(['id'],[last_key($table)]);

    # And finally, register this person in the "All Element Types" group.
    $self->register_instance(INSTANCE_GROUP_ID, GROUP_PACKAGE);

    return $self;
}

#------------------------------------------------------------------------------#

=item $element_type->_get_parts()

Call the list function of Bric::Biz::ElementType::Parts::Container to return a
list of conainer parts of this ElementType object, or return the existing parts
if weve already loaded them.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

sub _get_parts {
    my $self = shift;
    my ($id, $parts) = $self->_get(qw(id _parts));

    # Do not attempt to get the ElementType parts if we don't yet have an ID.
    return unless $id;

    unless ($parts) {
        $parts = Bric::Biz::ElementType::Parts::FieldType->href({
            element_type_id => $self->get_id,
            order_by        => 'place',
            active          => 1,
        });
        $self->_set(['_parts'], [$parts]);
    }

    return $parts;
}

##############################################################################

=back

=head2 Private Functions

=over 4

=item my $oc_coll = $get_oc_coll->($element_type)

Returns the collection of output channels for this element type. The
collection is a L<Bric::Util::Coll::OCElement|Bric::Util::Coll::OCElement>
object. See that class and its parent, L<Bric::Util::Coll|Bric::Util::Coll>,
for interface details.

B<Throws:>

=over 4

=item *

Bric::_get() - Problems retrieving fields.

=item *

Unable to prepare SQL statement.

=item *

Unable to connect to database.

=item *

Unable to select column into arrayref.

=item *

Unable to execute SQL statement.

=item *

Unable to bind to columns to statement handle.

=item *

Unable to fetch row from statement handle.

=item *

Incorrect number of args to Bric::_set().

=item *

Bric::set() - Problems setting fields.

=back

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

$get_oc_coll = sub {
    my $self = shift;
    my $dirt = $self->_get__dirty;
    my ($id, $oc_coll) = $self->_get('id', '_oc_coll');
    return $oc_coll if $oc_coll;
    $oc_coll = Bric::Util::Coll::OCElement->new(
        defined $id ? {element_type_id => $id} : undef
    );
    $self->_set(['_oc_coll'] => [$oc_coll]);
    $self->_set__dirty($dirt); # Reset the dirty flag.
    return $oc_coll;
};


=item my $site_coll = $get_site_coll->($element_type)

Returns the collection of sites for this element type. The collection is a
L<Bric::Util::Coll::Site|Bric::Util::Coll::Site> object. See that class and
its parent, L<Bric::Util::Coll|Bric::Util::Coll>, for interface details.

B<Throws:>

=over 4

=item *

Bric::_get() - Problems retrieving fields.

=item *

Unable to prepare SQL statement.

=item *

Unable to connect to database.

=item *

Unable to select column into arrayref.

=item *

Unable to execute SQL statement.

=item *

Unable to bind to columns to statement handle.

=item *

Unable to fetch row from statement handle.

=item *

Incorrect number of args to Bric::_set().

=item *

Bric::set() - Problems setting fields.

=back

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

$get_site_coll = sub {
    my $self = shift;
    my $dirt = $self->_get__dirty;
    my ($id, $site_coll) = $self->_get('id', '_site_coll');
    return $site_coll if $site_coll;
    $site_coll = Bric::Util::Coll::Site->new(
        defined $id ? {element_type_id => $id} : undef
    );
    $self->_set(['_site_coll'] => [$site_coll]);
    $self->_set__dirty($dirt); # Reset the dirty flag.
    return $site_coll;
};

=item my $key_name = $make_key_name->($name)

Takes an element type name and turns it into the key name. This is the name
that will be used in templates and in the super bulk edit interface.

B<Throws:> NONE.

B<Side Effects:> NONE.

B<Notes:> NONE.

=cut

$make_key_name = sub {
    my $n = lc($_[0]);
    $n =~ y/a-z0-9/_/cs;
    return $n;
};


1;
__END__

=back

=head1 NOTES

NONE.

=head1 AUTHOR

michael soderstrom <miraso@pacbell.net>

=head1 SEE ALSO

L<Bric|Bric>, L<Bric::Biz::Asset|Bric::Biz::Asset>,
L<Bric::Util::Coll::OCElement|Bric::Util::Coll::OCElement>.

=cut
