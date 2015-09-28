package Isucon5::Model;
use strict;
use warnings;
no warnings 'deprecated';
use utf8;
use Kossy;
use DBIx::Sunny;
use Encode;
use Digest::SHA qw/sha512_hex/;
use Text::Xslate;
use HTML::FillInForm::Lite;
use Path::Class qw/file dir/;
use Data::MessagePack;
use Gearman::Client;
use POSIX qw/strftime/;
sub p {
    use Data::Dumper;warn Dumper(@_);
}

our $PREFS = [
    '未入力',
    '北海道', '青森県', '岩手県', '宮城県', '秋田県', '山形県', '福島県', '茨城県', '栃木県', '群馬県', '埼玉県', '千葉県', '東京都', '神奈川県', '新潟県', '富山県',
    '石川県', '福井県', '山梨県', '長野県', '岐阜県', '静岡県', '愛知県', '三重県', '滋賀県', '京都府', '大阪府', '兵庫県', '奈良県', '和歌山県', '鳥取県', '島根県',
    '岡山県', '広島県', '山口県', '徳島県', '香川県', '愛媛県', '高知県', '福岡県', '佐賀県', '長崎県', '熊本県', '大分県', '宮崎県', '鹿児島県', '沖縄県'
];


my $encoder = Encode::find_encoding('utf-8');

my $cache_dir = dir('/var/isucon_cache');
my $ini_cache_dir = $cache_dir->subdir('ini');
my $mod_cache_dir = $cache_dir->subdir('mod');

for my $subdir (qw/index entry friends footprints/) {
    $ini_cache_dir->subdir($subdir)->mkpath;
    $mod_cache_dir->subdir($subdir)->mkpath;
}

my $fif = HTML::FillInForm::Lite->new();
my $tx = Text::Xslate->new(
    path => '/home/isucon/webapp/perl/views',
    syntax => 'Kolon',
    cache  => 2,
    module => ['Text::Xslate::Bridge::TT2Like','Number::Format' => [':subs']],
    input_layer => ':utf8',
    function => {
        fillinform => sub {
            my $q = shift;
            return sub {
                my ($html) = @_;
                return Text::Xslate::mark_raw( $fif->fill( \$html, $q ) );
            }
        }
    },
);
all_cache_tx($tx);
sub all_cache_tx {
    my $tx = shift;

    all_cache_remove_tx($tx);

    foreach my $path ( @{$tx->{path}} ) {
        dir($path)->recurse(callback => sub {
            my $file = shift;
            if ( $file =~ m{^\Q$path\E/(.*$tx->{suffix})$} ) {
                $tx->load_file($1);
            }
        });
    }
}
sub all_cache_remove_tx {
    my $tx = shift;

    foreach my $path ( @{$tx->{path}} ) {
        my $dir = dir($tx->{cache_dir}, Text::Xslate::uri_escape($path)) . "";
        next unless -d $dir;
        dir($dir)->recurse(callback => sub {
            my $file = shift;
            if ( $file =~ /^\Q$dir\E(.*$tx->{suffix}c)$/ ) {
                $file->remove;
            }
        });
    }
}

our $db;
sub db {
    $db ||= do {
        my %db = (
            host => $ENV{ISUCON5_DB_HOST} || 'localhost',
            port => $ENV{ISUCON5_DB_PORT} || 3306,
            username => $ENV{ISUCON5_DB_USER} || 'root',
            password => $ENV{ISUCON5_DB_PASSWORD},
            database => $ENV{ISUCON5_DB_NAME} || 'isucon5q',
        );
        DBIx::Sunny->connect(
            "dbi:mysql:database=$db{database};host=$db{host};port=$db{port}", $db{username}, $db{password}, {
                RaiseError => 1,
                PrintError => 0,
                AutoInactiveDestroy => 1,
                mysql_enable_utf8   => 1,
                mysql_auto_reconnect => 1,
            },
        );
    };
}

my $gearman_client;
my $gearman_client_last_pid;
sub gearman_client {
    if ( $gearman_client && $gearman_client_last_pid == $$ ) {
        return $gearman_client;
    }
    $gearman_client = do {
        my $client = Gearman::Client->new;
        $client->job_servers('127.0.0.1:3010');
        $client;
    };
}

my $users = {};
my $users_by_email = {};
my $users_by_account = {};

sub get_user {
    my $id = shift;
    $users->{$id}
}
sub get_user_from_email {
    my $email = shift;
    $users_by_email->{$email}
}
sub get_user_from_account {
    my $account = shift;
    $users_by_account->{$account}
}

sub is_friend {
    my ($user, $another_id) = @_;
    my $user_id = $user->{id};
    my $query = 'SELECT 1 FROM relations WHERE one = ? AND another = ? LIMIT 1';
    my $cnt = db->select_one($query, $user_id, $another_id);
    return $cnt > 0 ? 1 : 0;
}

sub permitted {
    my ($user, $another_id) = @_;
    $another_id == $user->{id} || is_friend($user, $another_id);
}


sub modify_user_index {
    my $user = shift;

    my $mod_file = $mod_cache_dir->file('index', $user->{id} . ".html");
    $mod_file->openw->print($encoder->encode(user_index($user)));
}

sub user_index_with_cache {
    my $user = shift;

    my $ini_file = $ini_cache_dir->file('index', $user->{id} . ".html");
    my $mod_file = $mod_cache_dir->file('index', $user->{id} . ".html");

    if ( -f $mod_file ) {
        return $mod_file->slurp;
    }
    elsif ( -f $ini_file ) {
        return $ini_file->slurp;
    }
    else {
        return user_index($user);
    }
}

sub user_index {
    my $user = shift;

    my $profile = db->select_row('SELECT * FROM profiles WHERE user_id = ?', $user->{id});
    my $entries_query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5';
    my $entries = [];
    for my $entry (@{db->select_all($entries_query, $user->{id})}) {
        my ($title, $content) = split(/\n/, $entry->{body}, 2);
        $entry->{title} = $title;
        push @$entries, $entry;
    }

    my $comments_for_me_query = q{
        SELECT *
        FROM comments
        WHERE to_user_id = ?
        ORDER BY created_at DESC
        LIMIT 10
    };
    my $comments_for_me = [];
    my $comments = [];
    for my $comment (@{db->select_all($comments_for_me_query, $user->{id})}) {
        my $comment_user = Isucon5::Model::get_user($comment->{user_id});
        $comment->{account_name} = $comment_user->{account_name};
        $comment->{nick_name} = $comment_user->{nick_name};
        push @$comments_for_me, $comment;
    }

    my $friends = [];
    my $relations = db->select_all('SELECT another FROM relations WHERE one = ?', $user->{id});
    my $friends_count = scalar @{$relations};
    for my $relation ( @{$relations} ) {
        push $friends, $relation->{another};
    }

    my $entries_of_friends = [];
    my $comments_of_friends = [];
    if ( $friends_count ) {
        for my $entry (@{db->select_all('SELECT id, user_id, body, created_at FROM entries where user_id IN(?) ORDER BY created_at DESC LIMIT 10', $friends)}) {
            my ($title) = split(/\n/, $entry->{body});
            $entry->{title} = $title;
            $entry->{user} = Isucon5::Model::get_user($entry->{user_id});
            push @$entries_of_friends, $entry;
        }

        my $comments = db->select_all(q{
            SELECT
                c.user_id comment_user_id
                ,e.user_id entry_user_id
                ,c.comment
                ,c.created_at
            FROM comments c
            join entries e on (e.id = c.entry_id)
            WHERE
                c.user_id IN(?)
                AND (
                    e.private = 0
                    OR 
                    EXISTS(select 1 from relations where one = ? and another = e.user_id limit 1)
                )
            ORDER BY c.created_at DESC
            LIMIT 10
        }, $friends, $user->{id});
        for my $comment (@{$comments}) {
            $comment->{entry_user}   = Isucon5::Model::get_user($comment->{entry_user_id});
            $comment->{comment_user} = Isucon5::Model::get_user($comment->{comment_user_id});
            push @$comments_of_friends, $comment;
        }
    }

    my $query = q{
        SELECT owner_id, print_date, print_datetime
        FROM footprint_fasts
        WHERE user_id = ?
        ORDER BY print_date desc, print_datetime desc
        LIMIT 10
    };
    my $footprints = [];
    for my $fp (@{db->select_all($query, $user->{id})}) {
        $fp->{user} = Isucon5::Model::get_user($fp->{owner_id});
        push @$footprints, $fp;
    }

    my $locals = {
        'user' => $user,
        'profile' => $profile,
        'entries' => $entries,
        'comments_for_me' => $comments_for_me,
        'entries_of_friends' => $entries_of_friends,
        'comments_of_friends' => $comments_of_friends,
        friends_count => $friends_count,
        'footprints' => $footprints
    };
    $tx->render('index.tx', $locals);
}

sub modify_entry_show {
    my $entry = shift;

    my $mod_file = $mod_cache_dir->file('entry', $entry->{id} . ".html");
    $mod_file->openw->print($encoder->encode(entry_show($entry)));
}

sub entry_show_with_cache {
    my $entry = shift;

    my $ini_file = $ini_cache_dir->file('entry', $entry->{id} . ".html");
    my $mod_file = $mod_cache_dir->file('entry', $entry->{id} . ".html");

    if ( -f $mod_file ) {
        return $mod_file->slurp;
    }
    elsif ( -f $ini_file ) {
        return $ini_file->slurp;
    }
    else {
        return entry_show($entry);
    }
}
sub entry_show {
    my $entry = shift;

    my ($title, $content) = split(/\n/, $entry->{body}, 2);
    $entry->{title} = $title;
    $entry->{content} = $content;
    my $owner = get_user($entry->{user_id});
    my $comments = [];
    for my $comment (@{db->select_all('SELECT * FROM comments WHERE entry_id = ?', $entry->{id})}) {
        $comment->{user} = Isucon5::Model::get_user($comment->{user_id});
        push @$comments, $comment;
    }
    my $locals = {
        'owner' => $owner,
        'entry' => $entry,
        'comments' => $comments,
    };
    $tx->render('entry.tx', $locals);
}

sub modify_friends {
    my $user = shift;

    my $mod_file = $mod_cache_dir->file('friends', $user->{id} . ".html");
    $mod_file->openw->print($encoder->encode(friends($user)));
}

sub friends_with_cache {
    my $user = shift;

    my $ini_file = $ini_cache_dir->file('friends', $user->{id} . ".html");
    my $mod_file = $mod_cache_dir->file('friends', $user->{id} . ".html");

    if ( -f $mod_file ) {
        return $mod_file->slurp;
    }
    elsif ( -f $ini_file ) {
        return $ini_file->slurp;
    }
    else {
        return friends($user);
    }
}
sub friends {
    my $user = shift;

    my $query = 'SELECT another, created_at FROM relations WHERE one = ? ORDER BY created_at DESC';
    my $friends = [];
    for my $rel (@{db->select_all($query, $user->{id})}) {
        $rel->{user} = Isucon5::Model::get_user($rel->{another});
        push @$friends, $rel;
    }
    $tx->render('friends.tx', { friends => $friends });
}

sub modify_footprints {
    my $user = shift;

    my $mod_file = $mod_cache_dir->file('footprints', $user->{id} . ".html");
    $mod_file->openw->print($encoder->encode(footprints($user)));
}

sub footprints_with_cache {
    my $user = shift;

    my $ini_file = $ini_cache_dir->file('footprints', $user->{id} . ".html");
    my $mod_file = $mod_cache_dir->file('footprints', $user->{id} . ".html");

    if ( -f $mod_file ) {
        return $mod_file->slurp;
    }
    elsif ( -f $ini_file ) {
        return $ini_file->slurp;
    }
    else {
        return footprints($user);
    }
}
sub footprints {
    my $user = shift;

    my $query = q{
        SELECT owner_id, print_date, print_datetime
        FROM footprint_fasts
        WHERE user_id = ?
        ORDER BY print_date desc, print_datetime desc
        LIMIT 50
    };
    my $footprints = [];
    for my $fp (@{db->select_all($query, $user->{id})}) {
        $fp->{user} = get_user($fp->{owner_id});
        push @$footprints, $fp;
    }
    $tx->render('footprints.tx', { footprints => $footprints });
}

sub enqueue {
    my ($jobname, @args) = @_;

    gearman_client()->dispatch_background($jobname, @args ? Data::MessagePack->pack([@args]) : ());
}
sub modify_cache_from_profile {
    my $job  = shift;
    my ($user_id) = @{Data::MessagePack->unpack($job->arg)};

warn sprintf("modify_cache_from_profile %s", $user_id);

    modify_user_index(get_user($user_id));
}
sub modify_cache_from_entry {
    my $job  = shift;
    my ($entry_id, $user_id) = @{Data::MessagePack->unpack($job->arg)};
    my $user = get_user($user_id);

warn sprintf("modify_cache_from_entry %s %s", $entry_id, $user_id);

    my $entry = db->select_row('select * from entries where id=?', $entry_id);

    modify_entry_show($entry);
    modify_user_index($user);
    for my $rel ( @{db->select_all('SELECT another FROM relations WHERE one = ?', $user->{id})} ) {
        modify_user_index(get_user($rel->{another}));
    }
}
sub modify_cache_from_comment {
    my $job  = shift;
    my ($entry_id, $user_id, $owner_id) = @{Data::MessagePack->unpack($job->arg)};

    my $entry = db->select_row('select * from entries where id=?', $entry_id);
    my $user  = get_user($user_id);
    my $owner = get_user($owner_id);

# これはすぐに必要になるのでリアルタイムでやる
#    modify_entry_show($entry);
warn sprintf("modify_cache_from_comment: %s %s %s", $entry_id, $user_id, $owner_id);
    # あなたへのコメント
    modify_user_index($owner);

    # あなたの友だちのコメント
    for my $rel ( @{db->select_all('SELECT another FROM relations WHERE one = ?', $user->{id})} ) {
        modify_user_index(get_user($rel->{another}));
    }
}
sub modify_cache_from_friend {
    my $job  = shift;
    my ($user_id, $another_id) = @{Data::MessagePack->unpack($job->arg)};

warn sprintf("modify_cache_from_friend %s %s", $user_id, $another_id);

    my $user    = get_user($user_id);
    my $another = get_user($another_id);

    modify_user_index($user);
    modify_friends($user);
    modify_user_index($another);
    modify_friends($another);
}
sub modify_cache_from_footprint {
    my $job  = shift;
    my ($user_id, $owner_id) = @{Data::MessagePack->unpack($job->arg)};

warn sprintf("modify_cache_from_footprint %s %s", $user_id, $owner_id);

    my $print_date     = strftime('%Y-%m-%d', localtime());
    my $print_datetime = strftime('%Y-%m-%d %H:%M:%S', localtime());
    my $query = q{
        INSERT INTO footprint_fasts
        (user_id,owner_id, print_date, print_datetime)
        VALUES (?,?,?,?)
        ON DUPLICATE KEY UPDATE print_datetime=values(print_datetime)
    };
    db->query($query, $user_id, $owner_id, $print_date, $print_datetime);
    my $user = get_user($user_id);
    modify_user_index($user);
    modify_footprints($user);
}

sub mk_initial_html {
    my $if_skip = shift;
    mk_initial_html_index($if_skip);
    mk_initial_html_friends($if_skip);
    mk_initial_html_footprints($if_skip);
    mk_initial_html_entry($if_skip);
}
sub mk_initial_html_index {
    my $if_skip = shift;

    for my $user ( values %{$users} ) {
        my $ini_file = $ini_cache_dir->file('index', $user->{id} . ".html");
        if ( $if_skip && -f $ini_file ) {
            next;
        }
        $ini_file->openw->print($encoder->encode(user_index($user)));
        warn 'index: ' . $user->{id}
    }
}
sub mk_initial_html_friends {
    my $if_skip = shift;

    for my $user ( values %{$users} ) {
        my $ini_file = $ini_cache_dir->file('friends', $user->{id} . ".html");
        if ( $if_skip && -f $ini_file ) {
            next;
        }
        $ini_file->openw->print($encoder->encode(friends($user)));
        warn 'friends: ' . $user->{id}
    }
}
sub mk_initial_html_footprints {
    my $if_skip = shift;

    for my $user ( values %{$users} ) {
        my $ini_file = $ini_cache_dir->file('footprints', $user->{id} . ".html");
        if ( $if_skip && -f $ini_file ) {
            next;
        }
        $ini_file->openw->print($encoder->encode(footprints($user)));
        warn 'footprints: ' . $user->{id}
    }
}
sub mk_initial_html_entry {
    my $if_skip = shift;

    my $min_id = 0;
    my $query = q{
        SELECT *
        FROM entries
        WHERE id > ?
        ORDER by id ASC
        limit 1000
    };
    while (1) {
        my $entries = db->select_all($query, $min_id);
        last unless @{$entries};
        for my $entry ( @{$entries} ) {
            my $ini_file = $ini_cache_dir->file('entry', $entry->{id} . ".html");
            if ( $if_skip && -f $ini_file ) {
                next;
            }
            $ini_file->openw->print($encoder->encode(entry_show($entry)));
            warn 'entry: ' . $entry->{id}
        }
        $min_id = $entries->[-1]->{id};
    }
}


sub init_process_read {
    my $query = q{
        SELECT u.*, s.salt
        FROM users u
        JOIN salts s ON u.id = s.user_id
    };
    my $result = db->select_all($query);
    for my $user (@{db->select_all($query)}) {
        $users->{$user->{id}} = $user;
        $users_by_email->{$user->{email}} = $user;
        $users_by_account->{$user->{account_name}} = $user;
    }
    $db = undef;
}
init_process_read();

1;
