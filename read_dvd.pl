#! /usr/bin/perl
# Reads the DVD IFO files and describes the structure
#
# Useful documentation:
#    https://dvd.sourceforge.net/dvdinfo/
#    https://en.wikibooks.org/wiki/Inside_DVD-Video/IFO_Files
#    https://en.wikipedia.org/wiki/DVD-Video#File_system
#    https://codedocs.xyz/xbmc/libdvdnav/dvdnavissues.html
#
# ffmpeg metadata format (for chapters):
#    https://ikyle.me/blog/2020/add-mp4-chapters-ffmpeg


use Getopt::Long;
Getopt::Long::Configure("bundling");
use Data::Dumper;
use Devel::StackTrace;
use Fcntl 'SEEK_CUR';
use feature 'signatures';
use strict;

my ($ForceDeinterlace, $SimpleMapping, $Name, $DEST, $Help, $MinRuntimeSeconds, $Debug);
$DEST=".";
$Name="DVD";
$MinRuntimeSeconds = 300;

if(@ARGV < 1) {
    die "usage: read_dvd.pl DIR/\n";
}

GetOptions(
    "help|h" => \$Help,
    "dest=s" => \$DEST,
    "debug" => \$Debug,
    "deinterlace|d" => \$ForceDeinterlace,
    "min-runtime|m=n" => \$MinRuntimeSeconds,
    "name|n=s" => \$Name,
    "simple-mapping" => \$SimpleMapping
    );
if($Help) {
    print <<EOHELP;
read_dvd.pl [options] SOURCEDIR/
Options:
    help|h           print this help message
    debug            Debug mode. Doesn't actually encode video.
    dest=DIR         the destination directory to store the encoded files in
    deinterlace|d    force de-interlacing even if the media info indicates that the media is not interlaced
    min-runtime|m=N  The minimum runtime for a title to extract and transcode, in seconds
    name|n=S         Specify the base name for videos (default is to auto-detect from the source directory)
    simple-mapping   Instead of mapping everything, take the default mapping (mostly for badly/weirdly encoded videos)
EOHELP
    exit(0);
}

my $BASEDIR = $ARGV[0];
$BASEDIR =~ s{/+$}{};
if($Name eq "DVD" && $BASEDIR =~ m{([^/]+)(?:/VIDEO_TS/?)?$}) {
    $Name = $1;
}


read_vmg();

################
# Reads the VMG IFO file
sub read_vmg {
    my $fh;
    open($fh, "<", "$BASEDIR/VIDEO_TS/VIDEO_TS.IFO") or open($fh, "<", "$BASEDIR/VIDEO_TS/VIDEO_TS.BUP") or die "Unable to open the main descriptor: $!\n";
    my $dvdvideo_vmg;
    sysread($fh, $dvdvideo_vmg, 12) == 12 or die "short read!\n";
    die "Directory does not contain a valid DVD descriptor" if $dvdvideo_vmg ne "DVDVIDEO-VMG";
    my $last_vmg_sector = read_int($fh);
    sysseek($fh, 0x1c, 0);
    my $last_ifo_sector = read_int($fh);
    sysseek($fh, 0x20, 0);
    my $version_number = read_short($fh);
    my $vmg_category = read_int($fh);
    my $volume_count = read_short($fh);
    my $volume_number = read_short($fh);
    my $side_id = read_byte($fh);
    sysseek($fh, 0x3E, 0);
    my $title_set_count = read_short($fh);
    my $provider_id = read_bytes($fh, 32);
    $provider_id =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
    my $vmg_pos = read_long($fh);
    sysseek($fh, 0x84, 0);
    my $first_chain_address = read_int($fh);

    print qq{The DVD is provided by "$provider_id"\n};
    print "The DVD contains $title_set_count titles.\n";
    print "This is volume $volume_number of $volume_count.\n";
    # print "First chain is at: $first_chain_address\n";

    sysseek($fh, 0xC0, 0);
    my $menu_vob_start = read_int($fh);
    my $title_table_start = read_int($fh);
    # print "title table start: $title_table_start\n";
    my $titles = read_vmg_title_table($fh, $title_table_start*2048);
    
    my @vts;
    foreach my $title_index (1..$title_set_count) {
        push(@vts, read_vts($title_index));
    }

    # print Dumper(@vts);

    ##############################
    # Calculate Title Play Times #
    ##############################
    foreach my $title (@$titles) {
        my $vts = $vts[$title->{video_title_set_number}-1];
        my $vts_title_no = $title->{title_in_vts};
        # print Dumper($vts->{titles});
        my $vts_title = $vts->{titles}->[$vts_title_no-1];
        my $playtime = calculate_title_playtime($vts, $vts_title);
        $title->{playtime} = $playtime;
    }
    
    ##################################
    # Analyze for the titles we want #
    ##################################
    my @titles_to_rip;
    my @cells_seen;
    foreach my $i (@vts) {
        push(@cells_seen, []);
    }
    # sort the titles by playtime and start lower to pick up episodes before "play all"
    foreach my $title (sort { $a->{playtime} <=> $b->{playtime} } @$titles) {
        print "Title $title->{index}: VTS $title->{video_title_set_number} title $title->{title_in_vts} ";
        my $vts = $vts[$title->{video_title_set_number}-1];
        my $vts_title_no = $title->{title_in_vts};
        my $vts_title = $vts->{titles}->[$vts_title_no-1];
        my $playtime = $title->{playtime};
        printf "playtime: %02d:%02d:%02d\n", $playtime/3600, ($playtime/60) % 60  , $playtime % 60;
        if($playtime > $MinRuntimeSeconds) {
            my @cells = find_all_cells($vts, $vts_title);
            # print Dumper($vts);
            if(!already_seen($cells_seen[$vts->{index}-1], \@cells)) {
                push(@titles_to_rip, { index => $title->{index}, vts => $vts, cells => [@cells], playtime => $title->{playtime}});
                foreach my $ptt (@{$vts_title->{ptts}}) {
                    my $chain = $vts->{program_chains}->[$ptt->{program_chain}-1];
                    # print "    vts $vts->{index} title $vts_title->{index}: $chain->{index}\n";
                }
            }
        }
    }

   
    ##################
    # Rip the titles #
    ##################
    foreach my $title (sort {int($b->{playtime}/180) <=> int($a->{playtime}/180) || $a->{index} <=> $b->{index}} @titles_to_rip) {
        printf("Saving title $title->{index}.\n");

        # TODO: make it an option to just extract rather than to pipe to ffmpeg
        # open(my $out, ">", "title.$title->{index}.mpv") or die "Unable to open video file.$!\n";

        # open all the vobs
        my $vobs = [];
        foreach my $file (sort glob(sprintf(qq{"$BASEDIR/VIDEO_TS/VTS_%02d_[1-9].VOB"}, $title->{vts}->{index}))) {
            open(my $fh, "<", $file) or die "Unable to open $file: $!\n";
            push(@$vobs,
                 {
                     name => $file,
                     fh => $fh,
                     sectors => ((stat($fh))[7])/2048
                 });
            # print "Opened $file\n";
        }

        
        # TODO: we need to run mediainfo on the VOB file that contains the first cells in the program and use that to determine features
        my $v = get_first_vob_file($title, $vobs);
        my $info = `mediainfo "$v"`;

        # Find out if it's interlaced
        my @yadif=();
        if($ForceDeinterlace || $info =~ m/Scan type\s*:\s*Interlaced/) {
            @yadif = ("-vf", "yadif=1:-1:0");
            print "Deinterlacing.\n";
        }

        # Audio
        my @audio=("-c:a", "libopus", "-b:a", "160k");
        if($info =~ m/Channel\(s\)\s+:\s+(\d+)\s+channels/) {
            if($1 > 2) {
                @audio = ("-c:a", "copy");
            }
        }

        # Mapping auto and subtitles
        my @mapping = ("-map", "0:v", "-map", "0:a?", "-map", "0:s?");
        if($SimpleMapping) {
            @mapping = ("-map", "0");
        }

        # TODO: write the chapter file /tmp/dvd_chapters.txt
        my $chapter_file = "/tmp/dvd.$$.chapters.txt";
        write_chapter_file($title, $chapter_file);
        # print "Wrote chapter file $chapter_file.\n";

        my $start_time = time();
        
        my $name = "$Name.$title->{index}";
        if($Debug) {
            print join(" ", "ffmpeg", "-loglevel", "30", "-stats", "-i", "-", "-i", $chapter_file, @yadif, @mapping, "-map_chapters", "1", "-c:v", "libsvtav1", "-b:v", "0", "-preset", "5", "-crf", "32", "-g", "240", "-pix_fmt", "yuv420p10le", "-svtav1-params", "tune=0", @audio, "-c:s", "copy", "${DEST}/${name}.av1.mkv", "\n");
            # Create the debug file (just a copy of the data)
            
            foreach my $cell (@{$title->{cells}}) {
                printf("Reading cell from VOB $cell->{vob_id} from $cell->{start} to $cell->{end}.\n");
            }
        } else {
            my $pid = open(my $out, "|-", "ffmpeg", "-loglevel", "30", "-stats", "-i", "-", "-i", $chapter_file, @yadif, @mapping, "-map_chapters", "1", "-c:v", "libsvtav1", "-b:v", "0", "-preset", "5", "-crf", "32", "-g", "240", "-pix_fmt", "yuv420p10le", "-svtav1-params", "tune=0", @audio, "-c:s", "copy", "${DEST}/${name}.av1.mkv" );
            if(!defined($pid)) {
                unlink($chapter_file);
                die "Unable to open ffmpeg! ($!\)\n";
            }

            
            foreach my $cell (@{$title->{cells}}) {
                # printf("Reading cell from VOB $cell->{vob_id}.\n");
                for(my $i = $cell->{start}; $i <= $cell->{end}; $i++) {
                    my $data = read_vob_sector($vobs, $i);
                    print $out $data;
                }
            }
            
            foreach my $vob (@$vobs) {
                close($vob->{fh});
            }
            
            close($out);
            waitpid($pid, 0);
        }
        my $stop_time = time();
        unlink($chapter_file);
        printf("Encoding finished. Took %d seconds.\n", ($stop_time - $start_time));
    }
}

####
# Writes the chapter file
sub write_chapter_file($title, $chapter_file) {
    # print "write_chapter_file($title, $chapter_file)\n";

    open(my $fh, ">", $chapter_file) or die "Unable to open $chapter_file for writing: $!\n";
    print $fh ";FFMETADATA1\n";
    print $fh "title=$Name\n";
    print $fh "\n";
    
    my $title_index = $title->{index};
    my $ptts = $title->{vts}->{titles}->[$title_index-1]->{ptts};
    my $last_time = 1;
    my $chapter_number = 1;
    foreach my $ptt (@$ptts) {
        my $cell = get_program_chain_cell($title->{vts}, $ptt->{program_chain}, $ptt->{program});
        # print Dumper($cell);
        my $playtime = $cell->{playtime};
        printf $fh "[CHAPTER]\nTIMEBASE=1/1000\nSTART=%d000\nEND=%d000\nTitle=Chapter %d\n\n", $last_time, $last_time + $playtime, $chapter_number;
        $last_time += $playtime;
        $chapter_number++;
    }
    
    close($fh);
}

####
#
sub get_program_chain_cell($vts, $chain_index, $program_index) {
    # print "get_program_chain_cell($vts, $chain_index, $program_index)\n";
    my $chain = $vts->{program_chains}->[$chain_index-1]->{chain};
    my $cell_index = $chain->{programs}->[$program_index-1];
    return $chain->{cells}->[$cell_index-1];
}

####
# Gets the filename of the first VOB file in the title (with path)
sub get_first_vob_file($title, $vobs) {
    my $cell = $title->{cells}->[0];
    my $sector = $cell->{start};
    my $offset = $sector;
    my $name;
    foreach my $vob (@$vobs) {
        # printf("  %d vs %d\n", $offset, $vob->{sectors});
        if($offset >= $vob->{sectors}) {
            # printf("  subtracting $vob->{sectors}\n");
            $offset -= $vob->{sectors};
            $name = $vob->{name}; # fallback
        } else {
            return $vob->{name};
        }
    }
    return $name;
}

####
# Read a sector from a vob and return it
sub read_vob_sector($vobs, $sector) {
    # print "read_vob_sector($vobs, $sector)\n";
    # print Dumper($vobs);
    my $fh;
    my $offset = $sector;
    foreach my $vob (@$vobs) {
        # printf("  %d vs %d\n", $offset, $vob->{sectors});
        if($offset >= $vob->{sectors}) {
            # printf("  subtracting $vob->{sectors}\n");
            $offset -= $vob->{sectors};
        } else {
            $fh = $vob->{fh};
            last;
        }
    }

    # print "Seeking to " . ($offset*2048)."\n";
    # print "   " . seek($fh, $offset*2048, 0) . "\n";
    my $data;
    my $count = read($fh, $data, 2048);
    $count == 2048 or die "short read ($count) $!\n";
    return $data;
}

####
# checks if we've already seen the cells
# @param $seen - an arrayref to the cells already seen
# @param $cells - the cells to check
sub already_seen($seen, $cells) {
    # print "already_seen($seen, $cells)\n";
    # print Dumper($seen);
    # TODO: implement this in a more sophisticated way, right now we're only comparing the starts and one cell could be inside of another
    my $ret = 0;

    my $first = $cells->[0]->{start};
    foreach my $s (@$seen) {
        if($first == $s->{start}) {
            $ret = 1;
            last;
        }
    }
    push(@$seen, @$cells);
    
    return $ret;
}

####
# Finds all the cells in a VTS title
# @return an array of hashrefs with the keys {vob_id, start, end}
sub find_all_cells($vts, $title) {

    my @cells;
    foreach my $ptt (@{$title->{ptts}}) {
        # print Dumper($ptt);
        my $chain = $vts->{program_chains}->[$ptt->{program_chain}-1]->{chain};
        my $cell = $chain->{cells}->[max(0,$chain->{programs}->[$ptt->{program}-1]-1)];
        push(@cells, { vob_id => $cell->{vob_id}, start => $cell->{vobu_start_sector}, end => $cell->{last_vobu_end_sector}});
    }

    return @cells;
}

####
# Calculates the playtime for a title
sub calculate_title_playtime($vts, $title) {
    # print Dumper($title);
    my $playtime;

    foreach my $ptt (@{$title->{ptts}}) {
        # print Dumper($ptt);
        my $chain = $vts->{program_chains}->[$ptt->{program_chain}-1]->{chain};
        $playtime += $chain->{cells}->[max(0,$chain->{programs}->[$ptt->{program}-1]-1)]->{playtime};
    }

    return $playtime;
}

####
# Reads the VMG title table 
sub read_vmg_title_table($fh, $addr) {
    sysseek($fh, $addr, 0) or die "Unable to seek to position: $!\n";

    my $title_count = read_short($fh);
    my $reserved = read_short($fh);
    my $end_address = read_int($fh);

    # print "title count: $title_count\n";

    my $titles = [];
    for(my $i = 0; $i < $title_count; $i++) {
        my $title = {};
        push(@$titles, $title);
        $title->{index} = $i+1;
        $title->{type} = read_byte($fh);
        $title->{angle_count} = read_byte($fh);
        $title->{chapter_count} = read_short($fh);
        $title->{parental_management_mask} = read_short($fh);
        $title->{video_title_set_number} = read_byte($fh);
        $title->{title_in_vts} = read_byte($fh);
        $title->{start_sector} = read_int($fh);

        # print Dumper($title);
        
        # print "Title $i:\n";
        # printf "\ttype: %08b\n", $type;
        # print "\tangles: $angle_count\n";
        # print "\tchapters: $chapter_count\n";
        # print "\tparental: $parental_management_mask\n";
        # print "\tvts: $video_title_set_number\n";
        # print "\ttitle in vts: $title_in_vts\n";
        # print "\tstart sector: $start_sector\n";
    }

    return $titles;
}

################
# Seeks to an absolute address or dies if it doesn't work
sub seek_abs($fh, $address) {
    if(!sysseek($fh, $address, 0)) {
        die "Unable to seek to $address: $!\n";
    }
}

################
# reads a VTS .IFO file
sub read_vts($index) {
    # print "Reading vts $index\n";

    my $filename = sprintf("$BASEDIR/VIDEO_TS/VTS_%02d_0.IFO", $index);
    my $filename2 = sprintf("$BASEDIR/VIDEO_TS/VTS_%02d_0.BUP", $index);
    my $fh;
    open($fh, "<", $filename) or open($fh, "<", $filename2) or die "Unable to open VTS file ($filename): $!\n";

    if(read_bytes($fh, 12) ne "DVDVIDEO-VTS") {
        die "VTS $index is not a valid VTS index.\n";
    }
    seek_abs($fh, 0xC8);
    my $title_pointer = read_int($fh)*2048;
    my $title_program_chain_table_pointer = read_int($fh)*2048;
    seek_abs($fh, 0xE0);
    my $title_cell_address_table_pointer = read_int($fh)*2048;
    my $title_vobu_address_map_pointer = read_int($fh)*2048;

    # print "title pointer: $title_pointer\n";
    # print "title program chain pointer: $title_program_chain_table_pointer\n";


    my @titles = read_vts_title_table($fh, $title_pointer);
    my @program_chains = read_vts_title_program_chain_table($fh, $title_program_chain_table_pointer);
    my @cell_addresses = read_cell_address_table($fh, $title_cell_address_table_pointer);
    # my @vobus = read_vobu_address_table($fh, $title_vobu_address_map_pointer);

    close($fh);

    # print "VTS $index:\n";
    # print Dumper(@titles);
    # print Dumper(@program_chains);
    # print Dumper(@cell_addresses);
    # print Dumper(@vobus);
    # print "\n\n";

    return {
        index => $index,
        titles => [@titles],
        program_chains => [@program_chains],
        cell_addresses => [@cell_addresses],
    };
}

##############
# Reads a top level cell address tabe
sub read_cell_address_table($fh, $address) {
    seek_abs($fh, $address);
    my @cells;

    my $vob_id_count = read_short($fh);
    my $reserved = read_short($fh);
    my $end_address = read_int($fh);
    my $cell_count = ($end_address-8)/12;

    for(my $i = 0; $i < $cell_count; $i++) {
        my $cell = {};
        push(@cells, $cell);
        $cell->{vob_id} = read_short($fh);
        $cell->{cell_id} = read_byte($fh);
        my $reserved = read_byte($fh);
        $cell->{start_sector} = read_int($fh);
        $cell->{end_sector} = read_int($fh);
    }
    
    return @cells;
}

##############
# Reads the VOBU address table
sub read_vobu_address_table($fh, $address) {
    seek_abs($fh, $address);
    # print "START ADDRESS: $address\n";
    my $end_address = read_int($fh);
    # print "END ADDRESS: $end_address\n";
    my $count = ($end_address - $address+1) / 4;
    # print "COUNT: $count\n";
    my @vobus;
    for(my $i = 0; $i < $count; $i++) {
        push(@vobus, read_int($fh));
    }

    return @vobus;
}


################
# Reads a VTS title table
sub read_vts_title_table($fh, $address) {
    my @titles;
    seek_abs($fh, $address);
    my $title_count = read_short($fh);
    my $reserved = read_short($fh);
    my $ptt_end_address = read_int($fh);

    # print "title count: $title_count\n";

    # Step 1: read in the PTT table offsets
    for(my $title_index = 1; $title_index <= $title_count; $title_index++) {
        my $title = {};
        push(@titles, $title);
        $title->{index} = $title_index;
        $title->{offset} = read_int($fh);
    }

    # Step 2: calculate the counts
    for(my $i = 0; $i < @titles; $i++) {
        if($i < @titles-1) {
            $titles[$i]->{ptt_count} = ($titles[$i+1]->{offset} - $titles[$i]->{offset})/4;
        } else {
            $titles[$i]->{ptt_count} = ($ptt_end_address - $titles[$i]->{offset}+1)/4;
        }
    }

    # Step 3: Read the PTT entries
    foreach my $title (@titles) {
        seek_abs($fh, $address + $title->{offset});
        $title->{ptts} = [];
        for(my $i = 0; $i < $title->{ptt_count}; $i++) {
            push(@{$title->{ptts}}, {program_chain => read_short($fh), program => read_short($fh) });
        }
    }

    return @titles;
}

################
# Reads the table which describes the program chains
# The documentation refers to this table as VTS_PGCI
# Title, here refers to program chains used by the titles as opposed to program chains used by menus. It doesn not containt title information.
sub read_vts_title_program_chain_table($fh, $address) {
    seek_abs($fh, $address);
    # printf("reading vts at %x\n", $address);
    
    # Header
    my $program_chain_count = read_short($fh);
    my $reserved = read_short($fh);
    my $end_address = read_int($fh);
    # print "program chain count: $program_chain_count\n";

    # Read the category and offsets
    my @chains;
    foreach my $i (1..$program_chain_count) {
        my $chain = {index => $i};
        push(@chains, $chain);
        $chain->{category} = read_int($fh);
        $chain->{offset} = read_int($fh);
    }

    # Read the chains
    my $pos = sysseek($fh, 0, SEEK_CUR);
    foreach my $chain (@chains) {
        # printf("reading chain $chain->{index} at offset %x (pos %x)\n", $chain->{offset}, sysseek($fh, 0, SEEK_CUR));
        if($chain->{offset} < $end_address) {
            $chain->{chain} = read_chain($fh, $address + $chain->{offset});
        } else {
            # printf STDERR "Skipping chain $chain->{index} (offset %x > %x) because it is corrupt. (pos %x)\n", $chain->{offset}, $end_address, sysseek($fh, 0, SEEK_CUR);
            $chain->{chain} = read_chain($fh, sysseek($fh, 0, SEEK_CUR)+8);
            # print Dumper($chain->{chain});
        }
    }

    return @chains;
}

sub read_chain($fh, $addr) {
    seek_abs($fh, $addr+2);
    # print "\tread_chain(fh, $addr)\n";

    my $chain = {};
    my $program_count = read_byte($fh);
    $chain->{program_count} = $program_count;
    my $cell_count = read_byte($fh);
    $chain->{cell_count} = $cell_count;
    # print "\tprogram count: $program_count\n";
    # print "\tcell count: $cell_count\n";
    read_bcd_time($fh, $chain);
    # printf("playtime: $chain->{playtime_text}\n");


    seek_abs($fh, $addr+0x9c);
    my $next_pgcn = read_short($fh);
    my $previous_pgcn = read_short($fh);
    my $group_pgcn = read_short($fh);
    my $still_time = read_byte($fh);
    my $playback_mode = read_byte($fh);
    seek_abs($fh, $addr+0xE4);
    my $commands_offset = read_short($fh);
    my $program_map_offset = read_short($fh);
    my $cell_playback_table_offset = read_short($fh);
    my $cell_position_table_offset = read_short($fh);

    # Read the Program Map
    my $programs = [];
    $chain->{programs} = $programs;
    seek_abs($fh, $addr + $program_map_offset);
    for(my $i = 0; $i < $program_count; $i++) {
        push(@$programs, read_byte($fh));
    }

    # Read the Cell playback table
    my $cells = [];
    $chain->{cells} = $cells;
    seek_abs($fh, $addr + $cell_playback_table_offset);
    for(my $i = 0; $i < $cell_count; $i++) {
        my $cell = {};
        push(@$cells, $cell);
        $cell->{flags} = read_byte($fh);
        $cell->{restricted} = ((read_byte($fh) >> 6) & 0x01);
        $cell->{still_time} = read_byte($fh);
        $cell->{command_number} = read_byte($fh);
        read_bcd_time($fh, $cell);
        $cell->{vobu_start_sector} = read_int($fh);
        $cell->{ilvu_end_sector} = read_int($fh);
        $cell->{last_vobu_start_sector} = read_int($fh);
        $cell->{last_vobu_end_sector} = read_int($fh);
    }

    # Read the cell position table
    seek_abs($fh, $addr + $cell_position_table_offset);
    for(my $i = 0; $i < $cell_count; $i++) {
        my $cell = $cells->[$i];
        $cell->{vob_id} = read_short($fh);
        my $reserved = read_byte($fh);
        my $cell->{id} = read_byte($fh);
    }

    return $chain;
}

sub read_bcd_time($fh, $hash) {
    my $playback_h_bcd = read_byte($fh);
    my $playback_m_bcd = read_byte($fh);
    my $playback_s_bcd = read_byte($fh);
    my $playback_f_bcd = read_byte($fh);

    my $hours = 10*($playback_h_bcd >> 4) + ($playback_h_bcd & 0xf);
    my $minutes = 10*($playback_m_bcd >> 4) + ($playback_m_bcd & 0xf);
    my $sec = 10*($playback_s_bcd >> 4) + ($playback_s_bcd & 0xf);
    my $frames = 10*(($playback_f_bcd >> 4) & 0x3) + ($playback_f_bcd & 0xf);
    $hash->{playtime} = 3600*$hours + 60*$minutes + $sec;
    $hash->{playtime_text} = sprintf("%02d:%02d:%02d:%02d", $hours, $minutes, $sec, $frames);
}

sub read_bytes {
    my ($fh, $count) = @_;
    my $val;
    if(sysread($fh, $val, $count) != $count) {
        die "Short read! $!";
    }
    return $val;
}

sub read_long {
    my ($fh) = @_;
    my $val;
    if(sysread($fh, $val, 8) != 8) {
        my $trace = Devel::StackTrace->new;
        print STDERR $trace->as_string;
        die "short read! $!\n";
    }
    my ($ret) = unpack('Q>', $val);
    return $ret;
}


sub read_int {
    my ($fh) = @_;
    my $val;
    if(sysread($fh, $val, 4) != 4) {
        my $trace = Devel::StackTrace->new;
        print STDERR $trace->as_string;
        die "short read! $!\n";
    }
    my ($ret) = unpack('L>', $val);
    return $ret;
}


sub read_short {
    my ($fh) = @_;
    my $val;
    if(sysread($fh, $val, 2) != 2) {
        my $trace = Devel::StackTrace->new;
        print STDERR $trace->as_string;
        die "short read! $!\n";
    }
    my ($ret) = unpack('S>', $val);
    return $ret;
}

sub read_byte {
    my ($fh) = @_;
    my $val;
    if(sysread($fh, $val, 1) != 1) {
        my $trace = Devel::StackTrace->new;
        print STDERR $trace->as_string;
        die "short read! $!\n";
    }
    my ($ret) = unpack('C', $val);
    return $ret;
}

sub max($a, $b) {
    return $a > $b ? $a : $b;
}

sub min($a, $b) {
    return $a > $b ? $b : $a;
}
