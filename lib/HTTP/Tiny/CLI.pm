package HTTP::Tiny::CLI;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use File::Which;
use IPC::Run;
use Proc::ChildError qw(explain_child_error);
#use String::ShellQuote;

sub new {
    my ($class, %attrs0) = @_;
    my $self = bless {}, $class;
    for my $k (keys %attrs0) {
        my $v = $attrs0{$k};
        if ($k =~ /\A(agent|default_headers|keep_alive|max_size|
                       http_proxy|https_proxy|proxy|no_proxy|timeout|
                       verify_SSL|

                       cli_search_order|curl_path|wget_path)\z/x) {
            $self->{$k} = $v;
        } else {
            die "Unknown/unsupported attribute '$k'";
        }
    }

    $self->{timeout} //= 60;
    $self->{default_headers} //= {};
    $self->{keep_alive} //= 1;
    $self->{max_redirects} //= 5;
    $self->{cli_search_order} //= 'curl,wget';
    $self->{curl_path} //= which('curl');
    $self->{wget_path} //= which('wget');
    if (!exists($self->{http_proxy})) {
        $self->{http_proxy} = $ENV{http_proxy} // $ENV{HTTP_PROXY};
    }
    if (!exists($self->{https_proxy})) {
        $self->{https_proxy} = $ENV{https_proxy} // $ENV{HTTPS_PROXY};
    }
    if (!exists($self->{proxy})) {
        $self->{proxy} = $ENV{all_proxy} // $ENV{ALL_PROXY};
    }
    {
        no strict 'refs';
        $self->{agent} //= '';
        my $def_agent = __PACKAGE__.'/'.(${__PACKAGE__ . '::VERSION'}//'dev');
        if (!length($self->{agent})) {
            $self->{agent} = $def_agent;
        } elsif ($self->{agent} =~ /\s\z/) {
            $self->{agent} .= $def_agent;
        }
    }
    $self;
}

sub request {
    my ($self, $method, $url, $options) = @_;
    $self->_request($method, $url, $options);
}

sub _request {
    my ($self, $method, $url, $options) = @_;
    $options //= {};
    for my $k (keys %$options) {
        if ($k =~ /\A(headers)\z/) {
        } elsif ($k eq 'content') {
            # XXX handle case when content is coderef
        } else {
            die "Unsupported/unknown option '$k'";
        }
    }

    my %headers = (%{$self->{default_headers}}, %{$options->{headers}//{}});

    my @cmd;
    my $res;
    for my $cli (split /\s*,\s*/, $self->{cli_search_order}) {
        if ($cli eq 'curl') {
            next unless defined($self->{curl_path});
            push @cmd, $self->{curl_path};
            push @cmd, "-q"; # must be the first opt, to skip reading config
            push @cmd, "-s";
            push @cmd, "-A", $self->{agent};
            push @cmd, "-X", $method;
            push @cmd, "-m", $self->{timeout};
            push @cmd, "-k" unless $self->{verify_SSL};
            push @cmd, "-D-";
            push @cmd, "--no-keep-alive" unless $self->{keep_alive};
            push @cmd, "--noproxy", $self->{no_proxy} if $self->{no_proxy};
            {
                my $proxy;
                if ($url =~ /^https/i && $self->{https_proxy}) {
                    $proxy = $self->{https_proxy};
                } elsif ($url =~ /^http/i && $self->{http_proxy}) {
                    $proxy = $self->{http_proxy};
                } elsif ($self->{proxy}) {
                    $proxy = $self->{proxy};
                }
                push @cmd, "--proxy", $proxy if $proxy;
            }
            for my $h (keys %headers) {
                my $hv = $headers{$h};
                for (ref($hv) eq 'ARRAY' ? @$hv : $hv) {
                    push @cmd, "-H", "$h: $_";
                }
            }
            push @cmd, $url;
            $log->tracef("Running: %s", \@cmd);
            my ($in, $out, $err, $h);
            $h = IPC::Run::start(\@cmd, \$in, \$out, $err);
            $h->finish or do {
                $res->{status}  = 599;
                $res->{reason}  = "Internal Exception";
                $res->{content} = explain_child_error(
                    {prog=>$self->{curl_path}});
                goto RETURN_RES;
            };
            $out =~ m!\AHTTP/\d\.\d (\d+).+\n((?:.|\n)+?)\R\R!m or do {
                $res->{status}  = 599;
                $res->{reason}  = "Internal Exception";
                $res->{content} = "Can't parse HTTP status line and headers ".
                    "from curl output";
                goto RETURN_RES;
            };
            $res->{status} = $1;
            my $headers = $2;
            $res->{headers} = {};
            while ($headers =~ /^([^:]+?)\s*:\s*(.*?)\R/gm) {
                if (exists $res->{headers}{$1}) {
                    unless (ref($res->{headers}{$1}) eq 'ARRAY') {
                        $res->{headers}{$1} = [$res->{headers}{$1}];
                    }
                    push @{ $res->{headers}{$1} }, $2;
                } else {
                    $res->{headers}{$1} = $2;
                }
            }
            $out =~ s/.+?\R\R//;
            $res->{content} = $out;
            goto RETURN_RES;
        } elsif ($cli eq 'wget') {
            next unless defined($self->{wget_path});
            # XXX how to disable config in wget? by feeding it empty config?
            # XXX wget doesn't support custom HTTP request method?
            die "Sorry, using 'wget' backend not implemented yet";
        } else {
            die "Unknown/unsupported CLI program '$cli'";
        }
    }
    die "Can't find any CLI backend to use (tried '$self->{cli_search_order}')";

  RETURN_RES:
    $res->{success} = $res->{status} =~ /\A(2|304)/;
    $res;
}

sub get    { my $self = shift; $self->request(GET    => @_) }
sub head   { my $self = shift; $self->request(HEAD   => @_) }
sub put    { my $self = shift; $self->request(PUT    => @_) }
sub post   { my $self = shift; $self->request(POST   => @_) }
sub delete { my $self = shift; $self->request(DELETE => @_) }

sub post_form {
    die "Not yet implemented";
}

sub mirror {
    die "Not yet implemented";
}

sub www_form_urlencode {
    die "Not yet implemented";
}

1;
# ABSTRACT: Use CLI network client (curl/wget) with HTTP::Tiny interface

=for Pod::Coverage ^(.+)$

=head1 SYNOPSIS

 use HTTP::Tiny::CLI;

 my $response = HTTP::Tiny::CLI->new->get('http://example.com/');

 die "Failed!\n" unless $response->{success};

 print "$response->{status} $response->{reason}\n";

 while (my ($k, $v) = each %{$response->{headers}}) {
     for (ref $v eq 'ARRAY' ? @$v : $v) {
         print "$k: $_\n";
     }
 }

 print $response->{content} if length $response->{content};


=head1 DESCRIPTION

B<NOTE: EARLY RELEASE. Many features like wget support, redirects, post data,
cookies are not yet implemented>.

This class lets you use CLI network clients (currently C<curl> and C<wget> are
supported) with an L<HTTP::Tiny> interface. It is an alternative you can try
when you must connect to https but L<IO::Socket::SSL> is not available (and you
cannot build it because there is no C compiler on the system).

Note that this is not a subclass of C<HTTP::Tiny>, but a look-alike object. Some
features of HTTP::Tiny are not supported or are implemented differently: XXX.


=head1 METHODS

=head1 new(%attributes) => obj

Aside from attributes known by HTTP::Tiny, there are additional attributes:

=over

=item * cli_search_order => str

A comma-separated list of CLI program names to search, in order. Currently only
wget and curl are supported. Either 'curl', 'wget', 'curl,wget' or 'wget,curl'.
The default is 'curl,wget'.

=item * curl_path => str

Set path to curl. The default is to search for "curl" in PATH.

=item * wget_path => str

Set path to wget. The default is to search for "wget" in PATH.

=back


=head1 CAVEATS

This module is currently not exactly "tiny": it depends on a couple of non-core
modules.

Some information (like "user:password" stanza in URL) might leak because it is
specified in command line which might be visible from B<ps> or other
process-table tools.


=head1 SEE ALSO

L<HTTP::Tiny>

=cut
