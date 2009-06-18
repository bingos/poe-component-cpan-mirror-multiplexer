use strict;
use warnings;
use POE qw(Component::CPAN::Mirror::Multiplexer);
my $test_httpd = POE::Component::CPAN::Mirror::Multiplexer->new( port => 8080 );
$poe_kernel->run();
exit 0;
