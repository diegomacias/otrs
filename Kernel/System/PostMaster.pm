# --
# PostMaster.pm - the global PostMaster module for OpenTRS
# Copyright (C) 2001 Martin Edenhofer <martin+code@otrs.org>
# --
# $Id: PostMaster.pm,v 1.2 2001-12-26 20:10:26 martin Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see 
# the enclosed file COPYING for license information (GPL). If you 
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --
package Kernel::System::PostMaster;

use strict;
use Kernel::System::DB;
use Kernel::System::EmailParser;
use Kernel::System::Ticket;
use Kernel::System::Article;
use Kernel::System::Queue;
use Kernel::System::PostMaster::FollowUp;
use Kernel::System::PostMaster::NewTicket;

use vars qw(@ISA $VERSION);

$VERSION = '$Revision: 1.2 $';
$VERSION =~ s/^.*:\s(\d+\.\d+)\s.*$/$1/;

# --
sub new {
    my $Type = shift;
    my %Param = @_;

    # allocate new hash for object
    my $Self = {}; 
    bless ($Self, $Type);

    # get Log Object
    $Self->{LogObject} = $Param{LogObject} || die "Got no LogObject!";

    # get ConfigObject
    $Self->{ConfigObject} = $Param{ConfigObject} || die "Got no ConfigObject!";
    $Self->{SystemID} = $Param{ConfigObject}->Get('SystemID');
    $Self->{TicketHook} = $Param{ConfigObject}->Get('TicketHook');

    $Self->{DBObject} = Kernel::System::DB->new(%Param);

    # get email 
    $Self->{Email} = $Param{Email} || die "Got no EmailBody!";
    my $EmailTmp = $Param{Email} || die "Got no EmailBody!";
    my @Email = @$EmailTmp;
    $Self->{ParseObject} = Kernel::System::EmailParser->new(
        Email => \@Email,
        OrigEmail => \@Email,
    );

    # for debug 0=off;1=on; 2=with GetHeaderParam;
    $Self->{Debug} = 0;

    # PostmasterUserID FIXME!!!
    $Self->{PostmasterUserID} = 1;
    $Self->{Priority} = 'normal';
    $Self->{State} = 'new';
    my @WantParam = (
    'From',
    'To',
    'Cc',
    'Reply-To',
    'ReplyTo',
    'Subject',
    'Message-ID',
    'Message-Id',
    'Precedence',
    'Mailing-List',
    'X-Loop',
    'X-No-Loop',
    'X-OTRS-Loop',
    'X-OTRS-Info',
    'X-OTRS-Priority',
    'X-OTRS-Queue',
    'X-OTRS-Ignore',
    'X-OTRS-State',
    'X-OTRS-CustomerNo',
    'X-OTRS-ArticleKey1',
    'X-OTRS-ArticleKey2',
    'X-OTRS-ArticleKey3',
    'X-OTRS-ArticleValue1',
    'X-OTRS-ArticleValue2',
    'X-OTRS-ArticleValue3',
    'X-OTRS-TicketKey1',
    'X-OTRS-TicketKey2',
    'X-OTRS-TicketValue1',
    'X-OTRS-TicketValue2',
    );
    $Self->{WantParam} = \@WantParam;

    return $Self;
}
# --
sub Run {
    my $Self = shift;
    my %Param = @_;

    # --
    # common opjects
    my $TicketObject = Kernel::System::Ticket->new(
         DBObject => $Self->{DBObject}, 
         ConfigObject => $Self->{ConfigObject},
         LogObject => $Self->{LogObject},
    );
    my $ArticleObject = Kernel::System::Article->new(
         DBObject => $Self->{DBObject},
         LogObject => $Self->{LogObject},
         ConfigObject => $Self->{ConfigObject},
    );
    my $NewTicket = Kernel::System::PostMaster::NewTicket->new(
        ParseObject => $Self->{ParseObject},
        DBObject => $Self->{DBObject},
        ArticleObject => $ArticleObject,
        TicketObject => $TicketObject,
        LogObject => $Self->{LogObject},
        ConfigObject => $Self->{ConfigObject},
    );


    # --
    # ConfigObjectrse section / get params
    # --
    my %GetParam = $Self->GetEmailParams();
    # --
    # should i ignore the incoming mail?
    # --
    if ($GetParam{'X-OTRS-Ignore'} =~ /yes/i) {
       $Self->{LogObject}->Log(
           MSG => "Droped Email (From: $GetParam{'From'}, MSG-ID: $GetParam{'Message-ID'}) " .
           "because the X-OTRS-Ignore is set (X-OTRS-Ignore: $GetParam{'X-OTRS-Ignore'})."
       );
       exit (0);
   }
   # --
   # ticket section
   # --
   # check if follow up
   my ($Tn, $TicketID) = $Self->CheckFollowUp(Subject => $GetParam{'Subject'}, TicketObject => $TicketObject);
   # Follow up ...
if ($Tn && $TicketID) {
    my $FollowUp = Kernel::System::PostMaster::FollowUp->new(
            DBObject => $Self->{DBObject},
            ArticleObject => $ArticleObject,
            TicketObject => $TicketObject,
            LogObject => $Self->{LogObject},
    );
    # check if it is possible to do the follow up
    my $QueueID = $TicketObject->GetQueueIDOfTicketID(
        TicketID => $TicketID,
    );
    # get follow up option (possible or not)
    my $QueueObject = Kernel::System::Queue->new(
        DBObject => $Self->{DBObject},
    );
    my $FollowUpPossible = $QueueObject->GetFollowUpOption(
        QueueID => $QueueID,
    );
    # get lock option (should be the ticket locked after the follow up)
    my $Lock = $QueueObject->GetFollowUpLockOption(
        QueueID => $QueueID,
    );
    # get ticket state 
    my $State = $TicketObject->GetState(
        TicketID => $TicketID,
    );
    # create a new ticket
    if ($FollowUpPossible =~ /new ticket/i && $State =~ /^close/i) {
        $Self->{LogObject}->Log(
            MSG=>"Follow up for [$Tn] but follow up not possible($State). Create new ticket."
        );
        # send mail && create new article
        $NewTicket->Run(
            InmailUserID => $Self->{PostmasterUserID},
            GetParam => \%GetParam,
            Email => $Self->{Email},
            Comment => "Because the old ticket [$Tn] is '$State'",
            AutoResponseType => 'auto reply/new ticket',
        );
        exit (0);
    }
    # reject follow up
    elsif ($FollowUpPossible =~ /reject/i && $State =~ /^close/i) {
        $Self->{LogObject}->Log(
            MSG=>"Follow up for [$Tn] but follow up not possible. Follow up rejected."
        );
        # send reject mail && and add article to ticket
        $FollowUp->Run(
            TicketID => $TicketID,
            InmailUserID => $Self->{PostmasterUserID},
            GetParam => \%GetParam,
            Lock => $Lock,
            Tn => $Tn,
            Email => $Self->{Email},
            QueueID => $QueueID,
            Comment => 'Follow up rejected.',
            AutoResponseType => 'auto reject',
        );
        exit (0);
    }
    # create normal follow up
    else {
        $FollowUp->Run(
            TicketID => $TicketID,
            InmailUserID => $Self->{PostmasterUserID},
            GetParam => \%GetParam,
            Lock => $Lock,
            Tn => $Tn,
            Email => $Self->{Email},
            State => 'open',
            QueueID => $QueueID,
            AutoResponseType => 'auto follow up',
        );
    }
}
# create new ticket
else {
    $NewTicket->Run(
        InmailUserID => $Self->{PostmasterUserID},
        GetParam => \%GetParam,
        Email => $Self->{Email},
        AutoResponseType => 'auto reply',
    );
}

}
# --
# CheckFollowUp
# --
sub CheckFollowUp {
    my $Self = shift;
    my %Param = @_;
    my $Subject = $Param{Subject} || '';
    my $TicketObject = $Param{TicketObject};

    if ($Self->{Debug} > 0) {
        $Self->{LogObject}->Log(
            Priority => 'debug',
            MSG => "CheckFollowUp Subject: '$Subject', SystemID: '$Self->{SystemID}', TicketHook: '$Self->{TicketHook}'",
        );
    }

    if ($Subject =~ /$Self->{TicketHook}:+.{0,1}($Self->{SystemID}\d{2,10})/i) {
        my $Tn = $1;
        my $TicketID = $TicketObject->CheckTicketNr(Tn => $Tn);
        if ($Self->{Debug} > 0) {
            $Self->{LogObject}->Log(
                Priority => 'debug',
                MSG => "CheckFollowUp: Tn: $Tn found!",
            );
        }
        if ($TicketID) {
            if ($Self->{Debug} > 0) {
                $Self->{LogObject}->Log(
                  Priority => 'debug',
                  MSG => "CheckFollowUp: ja, it's a follow up ($Tn/$TicketID)",
                );
            }
            return ($Tn, $TicketID);
        }
    }
    return;
}
# --
# GetEmailParams
# --
sub GetEmailParams {
    my $Self = shift;
    my %Param = @_;
    my %GetParam;
    # parse section
    my $WantParamTmp = $Self->{WantParam} || die "Got no \@WantParam ref";
    my @WantParam = @$WantParamTmp;
    foreach (@WantParam){
        if ($Self->{Debug} > 1) {
          $Self->{LogObject}->Log(
              Priority => 'debug',
              MSG => "$_: " . $Self->{ParseObject}->GetParam(WHAT => $_),
          );
        }
        $GetParam{$_} = $Self->{ParseObject}->GetParam(WHAT => $_);
    }
    if ($GetParam{'Message-Id'}) {
        $GetParam{'Message-ID'} = $GetParam{'Message-Id'};
    }
    if ($GetParam{'Reply-To'}) {
        $GetParam{'ReplyTo'} = $GetParam{'Reply-To'};
    }
    if (!$GetParam{'X-OTRS-Priority'}) {
        $GetParam{'X-OTRS-Priority'} = $Self->{Priority};
    }
    if (!$GetParam{'X-OTRS-State'}) {
        $GetParam{'X-OTRS-State'} = $Self->{State};
    }
    if ($GetParam{'Mailing-List'} || $GetParam{'Precedence'} || $GetParam{'X-Loop'}
             || $GetParam{'X-No-Loop'} || $GetParam{'X-OTRS-Loop'}) {
        $GetParam{'X-OTRS-Loop'} = 'yes';
    }
    $GetParam{Body} = $Self->{ParseObject}->GetMessageBody();
    return %GetParam;
}
# --

1;
