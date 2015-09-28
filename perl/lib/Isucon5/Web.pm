package Isucon5::Web;

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
use Isucon5::Model;
sub p {
    use Data::Dumper;warn Dumper(@_);
}

sub db { Isucon5::Model::db(@_) }

my ($SELF, $C);
sub session {
    $C->stash->{session};
}

sub stash {
    $C->stash;
}

sub redirect {
    $C->redirect(@_);
}

sub abort_authentication_error {
    session()->{user_id} = undef;
    $C->halt(401, encode_utf8($C->tx->render('login_fail.tx', { message => 'ログインに失敗しました' })));
}

sub abort_permission_denied {
    $C->halt(403, encode_utf8($C->tx->render('error.tx', { message => '友人のみしかアクセスできません' })));
}

sub abort_content_not_found {
    $C->halt(404, encode_utf8($C->tx->render('error.tx', { message => '要求されたコンテンツは存在しません' })));
}

sub authenticate {
    my ($email, $password) = @_;
#    my $query = <<SQL;
#SELECT u.id AS id, u.account_name AS account_name, u.nick_name AS nick_name, u.email AS email
#FROM users u
#JOIN salts s ON u.id = s.user_id
#WHERE u.email = ? AND u.passhash = SHA2(CONCAT(?, s.salt), 512)
#SQL
#    my $result = db->select_row($query, $email, $password);
    my $result = Isucon5::Model::get_user_from_email($email);
    my $digest = sha512_hex($password . $result->{salt});
    if ($digest ne $result->{passhash}) {
        abort_authentication_error();
    }
    session()->{user_id} = $result->{id};
    return $result;
}

sub current_user {
    my ($self, $c) = @_;
    my $user = stash()->{user};

    return $user if ($user);

    return undef if (!session()->{user_id});

    #$user = db->select_row('SELECT id, account_name, nick_name, email FROM users WHERE id=?', session()->{user_id});
    $user = Isucon5::Model::get_user(session()->{user_id});
    if (!$user) {
        session()->{user_id} = undef;
        abort_authentication_error();
    }
    return $user;
}

sub mark_footprint {
    my ($user_id) = @_;
    my $owner_id = current_user()->{id};
    if ($user_id != $owner_id) {
        Isucon5::Model::enqueue('modify_cache_from_footprint',$user_id, $owner_id);
    }
}

filter 'authenticated' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        if (!current_user()) {
            return redirect('/login');
        }
        $app->($self, $c);
    }
};

filter 'set_global' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        $SELF = $self;
        $C = $c;
        $C->stash->{session} = $c->req->env->{"psgix.session"};
        $app->($self, $c);
    }
};

get '/login' => sub {
    my ($self, $c) = @_;
    $c->render('login.tx', { message => '高負荷に耐えられるSNSコミュニティサイトへようこそ!' });
};

post '/login' => [qw(set_global)] => sub {
    my ($self, $c) = @_;
    my $email = $c->req->param("email");
    my $password = $c->req->param("password");
    authenticate($email, $password);
    redirect('/');
};

get '/logout' => [qw(set_global)] => sub {
    my ($self, $c) = @_;
    session()->{user_id} = undef;
    redirect('/login');
};

get '/' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;

    my $body = Isucon5::Model::user_index_with_cache(current_user());
    $c->res->status( 200 );
    $c->res->content_type('text/html; charset=UTF-8');
    $c->res->body( $body );
    $c->res;
};

get '/profile/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    my $owner = Isucon5::Model::get_user_from_account($account_name);
    my $prof = db->select_row('SELECT * FROM profiles WHERE user_id = ?', $owner->{id});
    $prof = {} if (!$prof);
    my $current_user = current_user();
    my $myself = $current_user->{id} == $owner->{id} ? 1 : 0;
    my $is_friend = Isucon5::Model::is_friend($current_user, $owner->{id});
    my $permitted = $is_friend || $myself;
    my $query;
    if ($permitted) {
        $query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5';
    } else {
        $query = 'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at LIMIT 5';
    }
    my $entries = [];
    for my $entry (@{db->select_all($query, $owner->{id})}) {
        my ($title, $content) = split(/\n/, $entry->{body}, 2);
        $entry->{title} = $title;
        $entry->{content} = $content;
        push @$entries, $entry;
    }
    mark_footprint($owner->{id});
    my $locals = {
        owner => $owner,
        profile => $prof,
        entries => $entries,
        private => $permitted,
        is_friend => $is_friend,
        current_user => $current_user,
        prefectures => $Isucon5::Model::PREFS,
    };
    $c->render('profile.tx', $locals);
};

post '/profile/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    if ($account_name ne current_user()->{account_name}) {
        abort_permission_denied();
    }
    my $first_name =  $c->req->param('first_name');
    my $last_name = $c->req->param('last_name');
    my $sex = $c->req->param('sex');
    my $birthday = $c->req->param('birthday');
    my $pref = $c->req->param('pref');

    my $prof = db->select_row('SELECT * FROM profiles WHERE user_id = ?', current_user()->{id});
    if ($prof) {
      my $query = <<SQL;
UPDATE profiles
SET first_name=?, last_name=?, sex=?, birthday=?, pref=?, updated_at=CURRENT_TIMESTAMP()
WHERE user_id = ?
SQL
        db->query($query, $first_name, $last_name, $sex, $birthday, $pref, current_user()->{id});
    } else {
        my $query = <<SQL;
INSERT INTO profiles (user_id,first_name,last_name,sex,birthday,pref) VALUES (?,?,?,?,?,?)
SQL
        db->query($query, current_user()->{id}, $first_name, $last_name, $sex, $birthday, $pref);
    }
    Isucon5::Model::enqueue('modify_cache_from_profile', current_user()->{id});
    redirect('/profile/'.$account_name);
};

get '/diary/entries/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    my $owner = Isucon5::Model::get_user_from_account($account_name);
    my $query;
    if (Isucon5::Model::permitted(current_user(), $owner->{id})) {
        $query = q{
            SELECT e.*,
                (SELECT COUNT(*) AS c FROM comments WHERE entry_id = e.id) comment_count
            FROM entries e
            WHERE e.user_id = ?
            ORDER BY e.created_at DESC
            LIMIT 20
        };
    } else {
        $query = q{
            SELECT e.*,
                (SELECT COUNT(*) AS c FROM comments WHERE entry_id = e.id) comment_count
            FROM entries e
            WHERE e.user_id = ? AND e.private=0
            ORDER BY e.created_at DESC
            LIMIT 20
        };
    }
    my $entries = [];
    for my $entry (@{db->select_all($query, $owner->{id})}) {
        my ($title, $content) = split(/\n/, $entry->{body}, 2);
        $entry->{title} = $title;
        $entry->{content} = $content;
        push @$entries, $entry;
    }
    mark_footprint($owner->{id});
    my $locals = {
        owner => $owner,
        entries => $entries,
        myself => (current_user()->{id} == $owner->{id}),
    };
    $c->render('entries.tx', $locals);
};

get '/diary/entry/:entry_id' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $entry_id = $c->args->{entry_id};
    my $entry = db->select_row('SELECT * FROM entries WHERE id = ?', $entry_id);
    abort_content_not_found() if (!$entry);
    my $owner = Isucon5::Model::get_user($entry->{user_id});
    if ($entry->{private} && !Isucon5::Model::permitted(current_user(), $owner->{id})) {
        abort_permission_denied();
    }

    mark_footprint($owner->{id});
    my $body = Isucon5::Model::entry_show_with_cache($entry);
    $c->res->status( 200 );
    $c->res->content_type('text/html; charset=UTF-8');
    $c->res->body( $body );
    $c->res;
};

post '/diary/entry' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $query = 'INSERT INTO entries (user_id, private, body) VALUES (?,?,?)';
    my $title = $c->req->param('title');
    my $content = $c->req->param('content');
    my $private = $c->req->param('private');
    my $body = ($title || "タイトルなし") . "\n" . $content;
    db->query($query, current_user()->{id}, ($private ? '1' : '0'), $body);
    Isucon5::Model::enqueue('modify_cache_from_entry', db->last_insert_id, current_user()->{id});
    redirect('/diary/entries/'.current_user()->{account_name});
};

post '/diary/comment/:entry_id' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $entry_id = $c->args->{entry_id};
    my $entry = db->select_row('SELECT * FROM entries WHERE id = ?', $entry_id);
    abort_content_not_found() if (!$entry);
    if ($entry->{private} && !Isucon5::Model::permitted(current_user(), $entry->{user_id})) {
        abort_permission_denied();
    }
    my $query = 'INSERT INTO comments (entry_id, user_id, comment, to_user_id) VALUES (?,?,?, ?)';
    my $comment = $c->req->param('comment');
    db->query($query, $entry->{id}, current_user()->{id}, $comment, $entry->{user_id});
    Isucon5::Model::enqueue('modify_cache_from_comment', db->last_insert_id, current_user()->{id}, $entry->{user_id});
    Isucon5::Model::modify_entry_show($entry);
    redirect('/diary/entry/'.$entry->{id});
};

get '/footprints' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;

    my $body = Isucon5::Model::footprints_with_cache(current_user());
    $c->res->status( 200 );
    $c->res->content_type('text/html; charset=UTF-8');
    $c->res->body( $body );
    $c->res;
};

get '/friends' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;

    my $body = Isucon5::Model::friends_with_cache(current_user());
    $c->res->status( 200 );
    $c->res->content_type('text/html; charset=UTF-8');
    $c->res->body( $body );
    $c->res;
};

post '/friends/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    my $user = Isucon5::Model::get_user_from_account($account_name);
    abort_content_not_found() if (!$user);

    if (!Isucon5::Model::is_friend(current_user(), $user)) {
        db->query('INSERT INTO relations (one, another) VALUES (?,?), (?,?)', current_user()->{id}, $user->{id}, $user->{id}, current_user()->{id});
        Isucon5::Model::enqueue('modify_cache_from_friend',current_user()->{id}, $user->{id});
        redirect('/friends');
    }
};

get '/initialize' => sub {
    my ($self, $c) = @_;
    db->query("DELETE FROM relations WHERE id > 500000");
    #db->query("DELETE FROM footprints WHERE id > 500000");
    db->query("DELETE FROM footprint_fasts WHERE print_date > '2015-09-01'");
    db->query("DELETE FROM entries WHERE id > 500000");
    db->query("DELETE FROM comments WHERE id > 1500000");
    `/bin/rm -f /var/isucon_cache/mod/index/*`;
    `/bin/rm -f /var/isucon_cache/mod/friends/*`;
    `/bin/rm -f /var/isucon_cache/mod/entry/*`;
    `/bin/rm -f /var/isucon_cache/mod/footprints/*`;
    1;
};

1;
