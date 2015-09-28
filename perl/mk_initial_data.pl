use FindBin;
use lib "$FindBin::Bin/local/lib/perl5";
use lib "$FindBin::Bin/lib";
use Isucon5::Model;

my $if_skip = shift // 1;

Isucon5::Model::mk_initial_html($if_skip);

