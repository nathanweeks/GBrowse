package Bio::Graphics::Karyotype;

# $Id: Karyotype.pm,v 1.6 2008-08-26 14:58:45 lstein Exp $
# Utility class to create a display of a karyotype and a series of "hits" on the individual chromosomes
# Used for searching


use strict;
use Bio::Graphics::Panel;
use GD 'gdSmallFont';
use CGI qw(img div b url table TR th td b escapeHTML a br);
use Carp 'croak';

sub new {
  my $class = shift;
  my %args            = @_;
  my $source          = $args{source}   or croak "source argument mandatory";
  my $lang            = $args{language};
  return bless {
		source   => $source,
		language => $lang,
		},ref $class || $class;
}

sub db             { shift->data_source->open_database()    }
sub data_source    { shift->{source}     }
sub language       { shift->{language}   }

sub trans       { 
  my $self = shift;
  my $lang = $self->language or return '';
  return $lang->tr(@_);
}

sub chrom_type  { 
    return shift->data_source->karyotype_setting('chromosome')   || 'chromosome';
}

sub chrom_width {
    return shift->data_source->karyotype_setting('chrom_width')  || 16;
}

sub chrom_height {
    return shift->data_source->karyotype_setting('chrom_height') || 100;
}

sub chrom_background {
    my $band_colors     = shift->data_source->karyotype_setting('bgcolor')
	|| 'gneg:white gpos25:gray gpos75:darkgray gpos100:black gvar:var stalk:#666666';
}

sub chrom_background_fallback {
    my $band_colors     = shift->data_source->karyotype_setting('bgfallback')
	|| 'yellow';
}

sub add_hits {
  my $self     = shift;
  my $features = shift;
  $self->{hits} ||= {};

  for my $f (@$features) {
    my $ref = $f->seq_id;
    push @{$self->{hits}{$ref}},$f;
  }
}

sub seqid_order {
    my $self = shift;
    return $self->{seqid_order} if exists $self->{seqid_order};

    my @chromosomes   = $self->chromosomes;
    my $sort_sub      = $self->sort_sub || \&by_chromosome_name;
    my @sorted_chroms = sort $sort_sub @chromosomes;
    my $i             = 0;
    my %order         = map {$_->seq_id => $i++} @sorted_chroms;

    return $self->{seqid_order} = \%order;
}

sub hits {
  my $self   = shift;
  my $seq_id = shift;

  my $hits = $self->{hits} or return;
  defined $seq_id          or return map {@$_} values %{$hits};

  my $list   = $self->{hits}{$seq_id} or return;
  return @$list;
}

# to sort chromosomes into their proper left->right order
sub sort_sub {
  my $self = shift;
  my $d    = $self->{sort_sub};
  $self->{sort_sub} = shift if @_;
  $d;
}

sub to_html {
  my $self        = shift;
  my $terms2hilite = shift;

  my $sort_order = $self->seqid_order;  # returns a hash of {seqid=>index}

  my $source     = $self->data_source;
  my $panels     = $self->{panels} ||= $self->generate_panels or return;

  my $html;
  for my $seqid (
      sort {$sort_order->{$a} <=> $sort_order->{$b}} keys %$panels
      ) {

    my $panel  = $self->{panels}{$seqid}{panel};

    my $url    = $source->generate_image($panel->gd);
    my $margin = Bio::Graphics::Panel->can('rotate') 
	         ? $self->chrom_height - $panel->gd->height
                 : 5;

    my $imagemap  = $self->image_map(scalar $panel->boxes,"${seqid}.");
    $html     .= 
	div(
	    {-style=>"float:left;margin-top:${margin}px;margin-left:0.5em;margin-right;0.5em"},
	    div({-style=>'position:relative'},
		img({-src=>$url,-border=>0}),
		$imagemap
	    ),
	    div({-align=>'center'},b($seqid))
	);
  }

  my $table = $self->hits_table($terms2hilite);
  return $html.br({-clear=>'all'}).$table;
}

# not really an imagemap, but actually a "rollover" map
sub image_map {
    my $self            = shift;
    my $boxes           = shift;

    my $chromosome = $self->chrom_type;

    my $divs = '';

    for (my $i=0; $i<@$boxes; $i++) {
	next if $boxes->[$i][0]->type eq $chromosome;

	my ($left,$top,$right,$bottom) =  @{$boxes->[$i]}[1,2,3,4];
	$left     -= 2;
	$top      -= 2;
	my $width  = $right-$left+3;
	my $height = $bottom-$top+3;
	
	my $name = $boxes->[$i][0]->display_name || "feature id #".$boxes->[$i][0]->primary_id;
	my $id   = $self->feature2id($boxes->[$i][0]);
	$divs .= div({-class => 'nohilite',
		      -id    => "box_${id}",
		      -style => "top:${top}px; left:${left}px; width:${width}px; height:${height}px",
		      -title => $name,
		      -onMouseOver=>"k_hilite_feature('$id',true)",
		      -onMouseOut =>"k_unhilite_feature('$id')"
		     },''
	    )."\n";
    }
    return $divs;
}

sub by_chromosome_length ($$) {
  my ($a,$b) = @_;
  my $n1     = $a->length;
  my $n2     = $b->length;
  return $n1 <=> $n2;
}

sub by_chromosome_name ($$){
  my ($a,$b) = @_;
  my $n1     = $a->seq_id;
  my $n2     = $b->seq_id;

  if ($n1 =~ /^\w+\d+/ && $n2 =~ /^\w+\d+/) {
    $n1 =~ s/^\w+//;
    $n2 =~ s/^\w+//;
    return $n1 <=> $n2;
  } else {
    return $n1 cmp $n2;
  }
}

sub chromosomes {
  my $self        = shift;
  my $db          = $self->db;
  my $chrom_type  = $self->chrom_type;
  return $db->features($chrom_type);
}

sub generate_panels {
  my $self = shift;
  my $chrom_type  = $self->chrom_type;
  my $chrom_width = $self->chrom_width;

  my @features    = $self->chromosomes;
  return unless @features;

  my $minimal_width  = 0;
  my $maximal_length = 0;

  for my $f (@features) {
    my $name  = $f->seq_id;
    my $width = length($name) * gdSmallFont->width;
    $minimal_width  = $width if $chrom_width < $width;
    $maximal_length = $f->length if $maximal_length < $f->length;
  }
  $chrom_width = $minimal_width 
    if $chrom_width eq 'auto';
  my $pixels_per_base = $self->chrom_height / $maximal_length;
  my $band_colors     = $self->chrom_background;
  my $fallback_color  = $self->chrom_background_fallback;

  # each becomes a panel
  my %results;
  for my $chrom (@features) {
    my $height = int($chrom->length * $pixels_per_base);
    my $panel  = Bio::Graphics::Panel->new(-width => $height,  # not an error, will rotate image later
					   -length=> $chrom->length,
					   -pad_top=>5,
					   -pad_bottom=>5,
	);

    if (my @hits  = $self->hits($chrom->seq_id)) {
      $panel->add_track(\@hits,
#			-glyph   => 'diamond',
#			-glyph   => 'generic',
			-glyph   => sub {
			    my $feature = shift;
			    return $feature->length/$chrom->length > 0.05
				? 'generic'
				: 'diamond';
			},
			-height  => 6,
			-bgcolor => 'red',
			-fgcolor => 'red',
			-bump    => -1,
	  );
    }

    my $method = $panel->can('rotate') ? 'add_track' : 'unshift_track';

    $panel->$method($chrom,
		    -glyph      => 'ideogram',                   # not an error, will rotate image later
		    -height     => $chrom_width,
		    -bgcolor    => $band_colors,
		    -bgfallback => $fallback_color,
		    -label    => 0,
		    -description => 0);

    $panel->rotate(1) if $panel->can('rotate');      # need bioperl-live from 20 August 2008 for this to work
    $results{$chrom->seq_id}{chromosome} = $chrom;
    $results{$chrom->seq_id}{panel}      = $panel;
  }

  return \%results;
}

sub feature2id {
    my $self              = shift;
    my $feature           = shift;
    return overload::StrVal($feature);
}

sub hits_table {
    my $self                  = shift;
    my $term2hilite           = shift;
    warn "term2hilite = $term2hilite";

    my @hits = $self->hits;

    my $url  = url(-path_info=>1)."?name=";

    my $regexp = join '|',($term2hilite =~ /(\w+)/g) 
	if defined $term2hilite;

    warn "regexp = $regexp";

    my $na   = $self->trans('NOT_APPLICABLE') || '-';

    my $sort_order = $self->seqid_order;
    
    # a big long map call here
    my @rows      = map {
	my $name  = $_->display_name;
	my $class = eval {$_->class};
	my $fid   =  $_->can('primary_id') ? "id:".$_->primary_id      # for inserting into the gbrowse search field
	           : $_->can('id')         ? "id:".$_->id
                   : $class                ? "$class:$name" 
                   : $name;
	my $id    = $self->feature2id($_);             # as an internal <div> id for hilighting
	my $pos   = $_->seq_id.':'.$_->start.'..'.$_->end;
	my $desc  = escapeHTML(Bio::Graphics::Glyph::generic->get_description($_));
	$desc =~ s/($regexp)/<b class="keyword">$1<\/b>/ig if $regexp;
	$desc =~ s/(\S{60})/$1 /g;  # wrap way long lines

	TR({-class=>'nohilite',
	    -id=>"feature_${id}",
	    -onMouseOver=>"k_hilite_feature('$id')",
	    -onMouseOut =>"k_unhilite_feature('$id')",
	   },
	    th({-align=>'left'},a({-href=>"$url$fid"},$name)),
	    td($_->method),
	    td($desc),
	    td(a({-href=>"$url$pos"},$pos)),
	    td($_->score || $na)
	    )
    } sort {
	$b->score    <=> $a->score
	|| $sort_order->{$a->seq_id} <=> $sort_order->{$b->seq_id}
        || $a->start <=> $b->start
	|| $a->end   <=> $b->end
    } @hits;

    my $count = $self->language ? b($self->trans('HIT_COUNT',scalar @hits)) : '';

    return 
	b($count),
	div({-id=>'scrolling_table'},
	    table({-class=>'searchbody',-width=>'100%'},
		  TR(
		      th({-align=>'left'},
			 [$self->trans('NAME'),
			  $self->trans('Type'),
			  $self->trans('Description'),
			  $self->trans('Position'),
			  $self->trans('score')
			 ])
		  ),
		  @rows)
	);
}


1;