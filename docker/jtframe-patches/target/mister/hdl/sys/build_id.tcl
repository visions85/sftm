
# SFTM-specific fix: copy sys_top.sdc into the Quartus project directory.
#
# ../mister.qsf references "SDC_FILE sys_top.sdc" (a bare filename, resolved
# relative to the Quartus project directory) with the comment "SDC file is
# copied and edited in the target folder" -- but nothing in the stock
# jtframe/jtcore project-generation flow actually performs that copy for
# this project. Every build has therefore reported:
#   Critical Warning (332012): Synopsys Design Constraints File file not
#   found: 'sys_top.sdc' ... the Compiler will not properly optimize the
#   design.
# and proceeded with NO clock constraints at all (no create_clock, no
# derive_pll_clocks) for the entire design -- meaning Quartus's timing
# analysis of every clock domain, including the CPU/ROM logic, has never
# actually been valid. This PRE_FLOW_SCRIPT_FILE hook is already the
# earliest point in the Quartus flow that runs after the project directory
# exists (same mechanism build_id_verilog below relies on), so it's the
# natural place to perform the copy ourselves.
#
# The vendored sys_top.sdc has no per-project placeholders (checked --
# it's generic MiSTer-framework port/PLL names throughout), so a plain
# copy is sufficient despite the "copied and edited" wording.
proc copySysTopSdc {} {
    set srcDir [file dirname [info script]]
    set src [file join $srcDir sys_top.sdc]
    set dst [file join [pwd] sys_top.sdc]
    if { [file exists $src] } {
        file copy -force $src $dst
        post_message "Copied $src -> $dst"
    } else {
        post_message -type error "sys_top.sdc not found at $src (expected alongside build_id.tcl)"
    }
}

# Build TimeStamp Verilog Module
# Jeff Wiencrot - 8/1/2011
# Sorgelig - 02/11/2019
proc generateBuildID_Verilog {} {

	# Get the timestamp (see: http://www.altera.com/support/examples/tcl/tcl-date-time-stamp.html)
	set buildDate "`define BUILD_DATE \"[clock format [ clock seconds ] -format %y%m%d]\""

	# Create a Verilog file for output
	set outputFileName "build_id.v"
	
	set fileData ""
	if { [file exists $outputFileName]} {
		set outputFile [open $outputFileName "r"]
		set fileData [read $outputFile]
		close $outputFile	
	}

	if {$buildDate ne $fileData} {
		set outputFile [open $outputFileName "w"]
		puts -nonewline $outputFile $buildDate
		close $outputFile
		# Send confirmation message to the Messages window
		post_message "Generated: [pwd]/$outputFileName: $buildDate"
	}
}

# Build CDF file
# Sorgelig - 17/2/2018
proc generateCDF {revision device outpath} {

	set outputFileName "jtag.cdf"
	set outputFile [open $outputFileName "w"]

	puts $outputFile "JedecChain;"
	puts $outputFile "	FileRevision(JESD32A);"
	puts $outputFile "	DefaultMfr(6E);"
	puts $outputFile ""
	puts $outputFile "	P ActionCode(Ign)"
	puts $outputFile "		Device PartName(SOCVHPS) MfrSpec(OpMask(0));"
	puts $outputFile "	P ActionCode(Cfg)"
	puts $outputFile "		Device PartName($device) Path(\"$outpath/\") File(\"$revision.sof\") MfrSpec(OpMask(1));"
	puts $outputFile "ChainEnd;"
	puts $outputFile ""
	puts $outputFile "AlteraBegin;"
	puts $outputFile "	ChainType(JTAG);"
	puts $outputFile "AlteraEnd;"
}

# SFTM-specific: copy the SignalTap capture file (sftm_ram_fault.stp) into
# the Quartus project directory and enable it for this build, same
# rationale/mechanism as copySysTopSdc above -- cores/sftm/mister/ is
# entirely gitignored (jtcore regenerates it from scratch every build), so
# a hand-authored .stp placed there directly would never survive a
# rebuild. This is temporary debugging instrumentation for the
# genuine_exc_fetch_addr=0x800410/word=0x003C investigation (see
# AGENTS.md, 2026-07-30) -- REMOVE this call (and the ENABLE_SIGNALTAP
# block below) once that investigation concludes, since SignalTap adds
# real ALM/M10K overhead and JTAG compile time to every build.
proc copyStpFile {} {
    set srcDir [file dirname [info script]]
    set src [file join $srcDir sftm_ram_fault.stp]
    set dst [file join [pwd] sftm_ram_fault.stp]
    if { [file exists $src] } {
        file copy -force $src $dst
        post_message "Copied $src -> $dst"
    } else {
        post_message -type error "sftm_ram_fault.stp not found at $src (expected alongside build_id.tcl)"
    }
}

# Enable SignalTap by appending plain lines directly to the .qsf TEXT FILE
# (matching copySysTopSdc/copyStpFile's own "just touch files on disk"
# style) instead of calling set_global_assignment through the API inside
# a project_open/project_close block. Tried the API approach first: it
# works (Analysis & Synthesis/Fitter/Assembler/Timing Analyzer each
# succeeded individually), but jtcore invokes each stage as a SEPARATE
# quartus_map/quartus_fit/quartus_asm/quartus_sta process, and modifying
# the QSF's assignments mid-flow (after the first stage already ran) makes
# each SUBSEQUENT stage's fresh process detect "Settings File changed
# outside of the Quartus Prime software", which cascades into "Full
# Compilation ended unexpectedly" at the very end despite every stage
# passing. Writing the lines into the QSF before the flow ever starts (this
# proc always runs before the very first project_open below) means nothing
# ever modifies the file mid-flow, so there's nothing for a later stage to
# detect as an external change. Idempotent via a plain text search so
# repeated invocations across stages don't duplicate the lines.
proc enableSignalTap {} {
    set qsfPath [file join [pwd] "sftm.qsf"]
    if { ![file exists $qsfPath] } {
        post_message -type error "sftm.qsf not found at $qsfPath -- cannot enable SignalTap"
        return
    }
    set f [open $qsfPath "r"]
    set content [read $f]
    close $f
    if { [string first "ENABLE_SIGNALTAP" $content] == -1 } {
        set f [open $qsfPath "a"]
        puts $f "set_global_assignment -name ENABLE_SIGNALTAP ON"
        puts $f "set_global_assignment -name USE_SIGNALTAP_FILE sftm_ram_fault.stp"
        puts $f "set_global_assignment -name SIGNALTAP_FILE sftm_ram_fault.stp"
        close $f
        post_message "Appended SignalTap assignments to $qsfPath"
    }
}

# TalkBack (Intel's opt-in usage-telemetry) must be enabled for SignalTap
# to work at all on Quartus Prime LITE (the free edition this project
# uses -- see docker/Dockerfile.quartus). This is a global Quartus
# preference, not a project assignment, so it's safe to call on every
# invocation (no QSF mid-flow modification involved). Wrapped in catch
# since its exact headless behaviour across containers is unverified --
# if it errors, the build should still proceed rather than abort on an
# instrumentation nicety.
catch { set_user_option -name TALKBACK_ENABLED on }

copySysTopSdc
copyStpFile
enableSignalTap

set project_name [lindex $quartus(args) 1]
set revision [lindex $quartus(args) 2]

if {[project_exists $project_name]} {
    if {[string equal "" $revision]} {
        project_open $project_name -revision [get_current_revision $project_name]
    } else {
        project_open $project_name -revision $revision
    }
} else {
    post_message -type error "Project $project_name does not exist"
    exit
}

set device  [get_global_assignment -name DEVICE]
set outpath [get_global_assignment -name PROJECT_OUTPUT_DIRECTORY]

if [is_project_open] {
    project_close
}

generateBuildID_Verilog
generateCDF $revision $device $outpath
