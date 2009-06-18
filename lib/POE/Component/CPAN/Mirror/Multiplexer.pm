package POE::Component::CPAN::Mirror::Multiplexer;

use strict;
use warnings;
use POE qw(Filter::HTTPD Filter::Stream Component::Client::HTTP Filter::HTTP::Parser);
use HTTP::Status qw(status_message RC_BAD_REQUEST RC_OK RC_LENGTH_REQUIRED);
use URI;
use File::Spec::Unix;
use Test::POE::Server::TCP;
use Test::POE::Client::TCP;

our $VERSION = '0.02';

our $agent = __PACKAGE__ . "$$";

our $errpage = <<HERE;
<html>
<head>
<title>500</title>
</head>
<body>
<h1>Server Error</h1>
<p>There was a problem retrieving the requested URL, sorry</p>
</body>
</html>
HERE

use MooseX::POE;

has 'address' => (
  is => 'ro',
);
 
has 'port' => (
  is => 'ro',
  default => sub { 0 },
  writer => '_set_port',
);
 
has 'hostname' => (
  is => 'ro',
  default => sub { require Sys::Hostname; return Sys::Hostname::hostname(); },
);
 
has '_httpd' => (
  accessor => 'httpd',
  isa => 'Test::POE::Server::TCP',
  lazy_build => 1,
  init_arg => undef,
);
 
has '_requests' => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {{}},
  init_arg => undef,
);

has 'error_page' => (
  is => 'ro',
  default => sub { $errpage },
);

has 'mirrors' => (
  is => 'ro',
  isa => 'ArrayRef',
  default => 
   sub { [
	  'http://cpan.cpantesters.org/',
          'http://cpan.hexten.net',
          'http://www.nic.funet.fi/pub/CPAN/',
          'http://www.cpan.org/',
         ] 
   },
);
 
sub _build__httpd {
  my $self = shift;
  Test::POE::Server::TCP->spawn(
     address => $self->address,
     port => $self->port,
     prefix => 'httpd',
     filter => POE::Filter::HTTP::Parser->new( type => 'server' ),
  );
}
 
sub START {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->httpd;
  return;
}
 
event 'httpd_registered' => sub {
  my ($kernel,$self,$httpd) = @_[KERNEL,OBJECT,ARG0];
  return;
};
 
event 'httpd_connected' => sub {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->httpd->client_wheel( $_[ARG0] )->set_output_filter( POE::Filter::Stream->new() );
  return;
};
 
event 'httpd_disconnected' => sub {
  my ($kernel,$self,$id) = @_[KERNEL,OBJECT,ARG0];
  my $httpc = delete $self->_requests->{$id}->{httpc};
  $kernel->post( $httpc, 'shutdown' );
  delete $self->_requests->{$id};
  return;
};
 
event 'httpd_client_input' => sub {
  my ($kernel,$self,$id,$request) = @_[KERNEL,OBJECT,ARG0,ARG1];
  $request->remove_header('Accept-Encoding');
  my @mirrors = @{ $self->mirrors };
  my $httpc = join('-',$agent,$id);
  $self->_requests->{$id} = { stream => 0, agent => $httpc, request => $request, mirrors => \@mirrors };
  POE::Component::Client::HTTP->spawn(
     Alias => $httpc,
     Streaming => 4096,
     FollowRedirects => 2,
  );
  $kernel->yield( '_fetch_uri', $id );
  return;
};

event '_fetch_uri' => sub {
  my ($kernel,$self,$id) = @_[KERNEL,OBJECT,ARG0];
  return unless defined $self->_requests->{$id};
  my $request = $self->_requests->{$id}->{request};
  my $httpc = $self->_requests->{$id}->{agent};
  my $mirror = shift @{ $self->_requests->{$id}->{mirrors} };
  # Hmmm what to do when we run out of mirrors
  unless ( $mirror ) {
     my $response = HTTP::Response->new( 500 );
     $response->content( $self->error_page );
     $kernel->post( $httpc, 'shutdown' );
     $self->httpd->disconnect( $id );
     $self->httpd->send_to_client( $id, $self->_response_headers( $response ) );
     delete $self->_requests->{$id};
     return;
  }
  my $req = HTTP::Request->new( GET => $self->_gen_uri( $mirror, $request->uri->path ) );
  $kernel->post(
    $httpc,
    'request',
    '_response',
    $req,
    "$id",
  );
  return;
};

sub _gen_uri {
  my $self = shift;
  my $host = shift;
  my $path = shift;
  my $uri = URI->new( $host );
  my @segs = $uri->path_segments;
  push @segs, $_ for split /\//, $path;
  $uri->path_segments( grep { $_ } @segs );
  return $uri->as_string;
}
 
event 'httpd_client_flushed' => sub {
  my ($kernel,$self,$id) = @_[KERNEL,OBJECT,ARG0];
  return;
};
 
event '_response' => sub {
  my ($kernel,$self,$request_packet,$response_packet) = @_[KERNEL,OBJECT,ARG0,ARG1];
  my $id = $request_packet->[1];
  my $response = $response_packet->[0];
  my $chunk = $response_packet->[1];
  unless ( $self->_requests->{$id}->{stream} ) {
     unless ( $response->is_success ) {
        $kernel->yield( '_fetch_uri', $id );
        return;
     }
     $self->_requests->{$id}->{stream} = 1;
     $self->httpd->send_to_client( $id, $self->_response_headers( $response ) );
  }
  unless ( $chunk ) {
     $self->_requests->{$id}->{stream} = 0;
     return;
  }
  $self->httpd->send_to_client( $id, $chunk );
  return;
};

sub _response_headers {
    my $self = shift;
    my $resp = shift;
    my $code = $resp->code;
    my $status_message = status_message($code) || "Unknown Error";
    my $message = $resp->message || "";
    my $proto = $resp->protocol || 'HTTP/1.0';
 
    my $status_line = "$proto $code";
    $status_line .= " ($status_message)" if $status_message ne $message;
    $status_line .= " $message" if length($message);
 
    # Use network newlines, and be sure not to mangle newlines in the
    # response's content.
 
    my @headers;
    push @headers, $status_line;
    push @headers, $resp->headers_as_string("\x0D\x0A");
 
    return join("\x0D\x0A", @headers, "") . $resp->content;
}

no MooseX::POE;

__PACKAGE__->meta->make_immutable;

"Yn dodi 'r proxy i mewn i CPAN ddrychau";

__END__


