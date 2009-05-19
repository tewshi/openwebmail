# $Id: xEMAIL.pm 79 2005-08-26 04:04:10Z chronos $
package BBCode::Tag::xEMAIL;
use base qw(BBCode::Tag);
use BBCode::Util qw(:parse :encode :text);
use strict;
use warnings;
our $VERSION = '0.01';

sub Tag($):method {
	return 'EMAIL';
}

sub Class($):method {
	return qw(LINK INLINE);
}

sub BodyPermitted($):method {
	return 1;
}

sub BodyTags($):method {
	return qw(TEXT ENT);
}

sub replace($):method {
	my $this = shift;
	my $text = $this->bodyHTML;
	my $url = parseMailURL decodeHTML $text;

	if(defined $url) {
		my $that = BBCode::Tag->new($this->parser, 'EMAIL', [ undef, $url->as_string ]);
		$that->pushBody(
			BBCode::Tag->new($this->parser, 'TEXT', [ undef, textURL($url) ])
		);
		return $that;
	} else {
		return BBCode::Tag->new($this->parser, 'TEXT', [ undef, $text ]);
	}
}

sub toBBCode($):method {
	return shift->replace->toBBCode;
}

sub toHTML($):method {
	return shift->replace->toHTML;
}

sub toLinkList($):method {
	return shift->replace->toLinkList;
}

1;