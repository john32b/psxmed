/********************************************************************
 * PSX Launcher Main Engine
 * ------------------------
 * 
 * TODO:
 *	- Some bits of code are named RAM, this is the old naming convention where
 *    the custom save dir was a "ramdisk" but now it can be anything. 
 *    so rename the "RAM" to something else, like "CUSTOM_SAVE_DIR"
 * 
 *******************************************************************/

package;

import djA.cfg.ConfigFileA;
import djNode.BaseApp;
import djNode.app.PismoMount;
import djNode.tools.FileTool;
import djNode.utils.CLIApp;
import djNode.utils.ProcUtil;
import haxe.crypto.Md5;
import djA.cfg.ConfigFileB;
import js.Node;
import js.lib.Error;
import js.node.ChildProcess;
import js.node.Fs;
import js.node.Os;
import js.node.Path;
import js.node.Process;
import sys.io.File;

typedef GameEntry = {
	var name:String;
	var path:String;
	var ext:String; // extension in lower case
	var isZIP:Bool;	// is ZIP,PFO,CFS ( and needs to be mounted with pismo )
					// note this is calculated at gamePrepare()
}

class Engine
{
	public static var NAME = "Mednafen PSX Custom Launcher";
	public static var VER = "0.5"; //DEV

	// Compatible ISO DIR extensions
	static var ext_normal = [".cue", ".m3u"];
	static var ext_mountable = [".pfo", ".zip", ".cfs"];

	static var file_config = "config.ini";
	static var file_config_empty = "config_empty.ini";
	static var MEDNAFEN_EXE = "mednafen.exe";
	static var PSX_CFG = "psx.cfg";
	
	
	// User Settings 
	// Key => "psx config field" - "default value" - "Option1|Option2|...|OptionN"
	public var SETTING:Map<String,String> = [
		"bilinear" => 'psx.videoip-1-0|1|x|y',
		"stretch" => 'psx.stretch-aspect_mult2-0|full|aspect|aspect_int|aspect_mult2',
		"shader" => 'psx.shader-none-none|autoip|autoipsharper|scale2x|sabr|ipsharper|ipxnoty|ipynotx|ipxnotysharper|ipynotxsharper|goat',
		"special" => 'psx.special-none-none|hq2x|hq3x|hq4x|scale2x|scale3x|scale4x|2xsai|super2xsai|supereagle|nn2x|nn3x|nn4x|nny2x|nny3x|nny4x',
		"fs" => 'video.fs-1',	// toggle state default
		"blur" => 'psx.tblur-0',// toggle state default
		
		"widen" => 'psx.sc_widen-0',
		"wsc" => 'psx.sc_win-3',
		"fsc" => 'psx.sc_fs-2'
	];
	

	// Program Config read from `config.ini`
	public var cfg = {
		path_iso : "",
		path_mednafen : "",		// full path
		path_savedir: "",		// full path
		path_autorun: "",
		terminal_size: "",
		pismo_enable:false,
		autosave:false,
		mednafen_states:"mcs", 	// is not the full path
		mednafen_saves:"sav"	// is not the full path
	};
	
	// Final full path of Mednafen States and Saves
	var path_med_states = "";
	// Final full path of Mednafen States and Saves
	var path_med_saves = "";

	// This gets filled on config_load
	public var flag_use_altsave(default, null):Bool = false;

	// The actual games found in the ISO dir
	public var ar_games:Array<GameEntry>;

	// Read this error in case of fatal exit
	public var ERROR:String = null;

	// Read this to get operations LOG
	public var OPLOG:String;

	// Set Externally, called whenever a game closes
	public var onMednafenExit:Void->Void;

	// The engine first prepares a game, then launches it
	public var current:GameEntry;			// Currently prepared game
	public var index:Int = -1;				// Prepared game index
	public var saves_local:Array<String>; 	// Fullpath of all LOCAL saves (states+MCR)
	public var saves_ram:Array<String>;   	// Fullpath of all RAM saves   (states+MCR)

	// If a game needs to be mounted (zip) this will hold the game full path.
	// so that it can be unmounted later. It checks for null to figure out mounted game or not.
	var mountedPath:String = null;
	
	// Object representation of 'psx.cfg' I can write values and call save()
	var psxcfg:ConfigFileA;

	//---------------------------------------------------;

	// DEV: I am initializing the engine in init(); so that I can get a return success from it
	public function new(){}

	/**
	   Initialize
	   - Throws errors (read engine.error)
	   @return
	**/
	public function init():Bool
	{
		CLIApp.FLAG_LOG_QUIET = false;

		try{
			_load_parse_config();
			_scan_iso_dir();
			_check_autorun();
			_get_psxcfg();
		}catch (e:String) {
			ERROR = e;
		}
		catch (e:js.lib.Error) {
			trace(e.stack);
			ERROR = "Generic filesystem Error";
		}
		
		return (ERROR == null);
	}//---------------------------------------------------;



	/**  Loads `CONFIG` file and populates variables
	     Also checks for paths in config file if valid
		 ! THROWS string errors
		 : sub of init()
	**/
	function _load_parse_config()
	{
		var ini:ConfigFileB;
		try { ini = new ConfigFileB(sys.io.File.getContent( BaseApp.app.getAppPathJoin(file_config) ) ); }
		catch (_) throw "Config file Read/Parse Error";

		var S = ini.data.get('settings');
		if (S == null) throw "Config File does not have a [settings] section";
		
		var gn = (p)->Path.normalize(S.get(p));
		
		cfg.path_iso = gn("isos");
		cfg.path_mednafen = gn("mednafen");
		cfg.path_savedir = gn("savedir");
		cfg.path_autorun = gn("autorun");
		cfg.mednafen_saves = gn("mednafen_saves");
		cfg.mednafen_states = gn("mednafen_states");
		cfg.terminal_size = S.get("size");
		cfg.autosave = Std.parseInt(S.get("autosave") ) == 1;
		cfg.pismo_enable = Std.parseInt(S.get("pismo_enable") ) == 1;
		

		// -- Check if settings are valid
		if (cfg.path_iso.length < 2) throw 'ISOPATH not set';
		if (cfg.path_mednafen.length < 2) throw 'MEDNAFEN PATH not set';
		if (!FileTool.pathExists(cfg.path_iso))	throw 'ISOPATH "${cfg.path_iso}" does not exist';
		if (!FileTool.pathExists(cfg.path_mednafen)) throw 'MEDNAFEN PATH "${cfg.path_mednafen}" does not exist';
		if (!FileTool.pathExists(Path.join(cfg.path_mednafen, MEDNAFEN_EXE))) throw 'Can\'t find "$MEDNAFEN_EXE" in "${cfg.path_mednafen}"';

		path_med_saves = Path.resolve(cfg.path_mednafen, cfg.mednafen_saves);
		path_med_states = Path.resolve(cfg.path_mednafen, cfg.mednafen_states);
		
		flag_use_altsave = cfg.path_savedir.length > 1;

		if (flag_use_altsave)
		{
			// Throws string errors -- If already exists, will do nothing
			FileTool.createRecursiveDir(cfg.path_savedir);
		}

		trace('Engine : Loaded Config.ini :' , cfg);
		trace(' .mednafen states : ' + path_med_states);
		trace(' .mednafen saves  : ' + path_med_saves);
		trace(' ------------------- ');
	}//---------------------------------------------------;


	/**
	   : Scans path for games and fills vars
	   : sub of init()
	   : DEV
		- Scans all valid extension game files, adds entry to `ar_games`
		- THEN Scans all M3U files and deletes duplicates from the main `ar_games`
		- Alphabetize the end array
	**/
	function _scan_iso_dir()
	{
		ar_games = [];
		var m3u:Array<String> = [];
		var extToScan = ext_normal;
		if (cfg.pismo_enable) extToScan = extToScan.concat(ext_mountable);
		var fileList = FileTool.getFileListFromDirR(cfg.path_iso, extToScan);

		for (i in fileList)
		{
			var entry = {
				name : Path.basename(i, Path.extname(i)),
				path : i,
				ext  : FileTool.getFileExt(i),
				isZIP : false
			};
			ar_games.push(entry);
			if (entry.ext == ".m3u") m3u.push(i);
		}// --

		// Open the M3U files and remove their entries from the main DB
		//  - e.g.
		//  - Keep 'Final Fantasy VII.m3u' but remove all of the disks from the
		//  - main list (disk1,disk2,disk3), so it is cleaner.
		for (i in m3u)
		{
			// FilePaths inside the M3U files:
			var files = Fs.readFileSync(i).toString().split(Os.EOL);

			for (ii in files)
			{
				// I can delete in a loop as long as it's in reverse [OK]
				var x = ar_games.length;
				while (--x >= 0)
				{
					if (ar_games[x].name == Path.basename(ii, Path.extname(ii)))
					{
						ar_games.splice(x, 1);
					}
				}
			}
		}

		//-- Alphabetize the results
		ar_games.sort((a,b)->{
			return a.name.toLowerCase().charCodeAt(0) - b.name.toLowerCase().charCodeAt(0);
		});

		trace('-> Number of games found : [${ar_games.length}]');

		#if debug
		for (g in ar_games) trace('  - ${g.name} ,${g.path} ');
		#end
	}//---------------------------------------------------;


	// Checks if an autorun is set, checks if the process is already running, and starts it if not.
	// : sub of init()
	// --
	function _check_autorun()
	{
		if (cfg.path_autorun.length < 2) {
			return;
		}
		var exe = Path.basename(cfg.path_autorun);
		var r = ProcUtil.getTaskPIDs(exe);
		if (r.length == 0)
		{
			CLIApp.quickExec('START /I ${cfg.path_autorun}', (a,b,c)->{
				OPLOG = 'Launched "$exe" [OK]';
			});
		}else{
			OPLOG = '"$exe" Already running';
		}
	}//---------------------------------------------------;

	
	// - load 'psx.cfg' and set it up
	function _get_psxcfg()
	{
		psxcfg = new ConfigFileA(Path.join(cfg.path_mednafen, PSX_CFG));
		
		if (!psxcfg.load()) {
			// But it is going to be created at save(), so no big deal
			trace("Note: 'psx.cfg' does not exist");
		}
		
		// Does the CFG needs saving? Did I write any values to it?
		var S = false;
		
		// Quick function to check for a field, and set it if not what it expects
		var ensure = (f,k)->{
			if (psxcfg.get(f) != k){
				psxcfg.set(f, k);
				S = true;
			}
		}// --
		
		ensure('filesys.fname_state', "%f.%X");
		ensure('filesys.fname_sav', "%F.%x");
		
		if (flag_use_altsave) 
		{
			ensure('filesys.path_state', cfg.path_savedir);
			ensure('filesys.path_sav', cfg.path_savedir);
		}
		
		// -------
		if (S){
			trace("> Wrote some default values, saving `psx.cfg");
			if (!psxcfg.save()) {
				throw "Cannot write to 'psx.cfg', do you have write access?";
			}
		}else{
			trace("> No need to modify `psx.cfg`");
		}
		
	}//---------------------------------------------------;
	

	/**
	   Request a game index to be prepared to be launched
	   Called when you select a game from the list and the options are displayed
	   - Reads save status
	   @param	i
	**/
	public function prepareGame(i:Int)
	{
		index = i;
		current = ar_games[index];
		current.isZIP = ext_mountable.indexOf( current.ext ) >= 0;
		saves_local = getLocalSaves(i);
		saves_ram = getRamSaves(i);
		trace('Preparing Game: "${current.name}" | ZIP:"${current.isZIP}"');
		trace("Saves Local", saves_local);
		trace("Saves Ram", saves_ram);
	}//---------------------------------------------------;

	/**
		PRE: A Game is prepared
	**/
	public function launchGame():Bool
	{
		trace('>> Launching game : ${current.name}');

		if (current.isZIP)
		{
			// Mount the .zip then launch
			mountedPath = PismoMount.mount(current.path);

			// :: This should not happen ever, but check anyway
			if (mountedPath == null)
			{
				ERROR = "Could not mount game";
				return false;
			}

			// - Figure out what kind of files are there in the archive
			// - Prefer .M3u files over .Cue files

			var l:String = null; // File to launch
			for (f in FileTool.getFileListFromDir(mountedPath))
			{
				switch (FileTool.getFileExt(f)) {
					case ".cue" : l = f;
					case ".m3u" : l = f; break;
					default:
				}
			}
			
			if (l == null)
			{
				ERROR = "No '.cue|.m3u' files found";
				PismoMount.unmount(mountedPath);
				return false;
			}

			startMednafen(Path.join(mountedPath, l));
		}else
		{
			// Normal .cue/.m3u game, Launch normally
			mountedPath = null;
			startMednafen(current.path);
		}

		return true;
	}//---------------------------------------------------;


	/**
	   Save Exists locally and ramdrive Exists
	   Does not re-alter VARS, you need to prepare game again later
	   @OPLOG
	**/
	public function copySave_Pull()
	{
		if (saves_local.length == 0) return; // Just in case

		var numCopied:Int = 0;
		var numTotal:Int = saves_local.length;

		for (i in saves_local)
		{
			var newsave = Path.join(cfg.path_savedir, Path.basename(i));
			// Don't copy over
			if (FileTool.pathExists(newsave))
			{
				trace('$newsave - Already exists - [SKIP]');
			}else
			{
				FileTool.copyFileSync(i, newsave);
				numCopied++;
				trace('$newsave - Copied to RAM - [OK]');
			}
		}

		OPLOG = 'Copied ($numCopied/$numTotal) saves to current Save dir';
	}//---------------------------------------------------;

	/**
	   Copy RAM to LOCAL and overwrite everything
	   Does not re-alter VARS, you need to prepare game again later
	   @OPLOG
	**/
	public function copySave_Push()
	{
		if (saves_ram.length == 0) return; // Just in case

		var numCopied:Int = 0;
		var numTotal:Int = saves_ram.length;

		for (i in saves_ram)
		{
			var dest:String;
			if (FileTool.getFileExt(i) == ".mcr")
			{
				dest = Path.join(path_med_saves, Path.basename(i));
			}else
			{
				dest = Path.join(path_med_states, Path.basename(i));
			}

			// Check if file is the same, don't overwrite same files
			// NOTE, dest could not exist yet
			if (FileTool.pathExists(dest) && filesAreSame(i, dest) )
			{
				trace('$dest - already exists with same contents, [SKIPPING]');
			}
			else
			{
				FileTool.copyFileSync(i, dest);
				trace('$dest - Copied to LOCAL - [OK]');
				numCopied++;
			}

		}
		OPLOG = 'Copied ($numCopied/$numTotal) saves to Mednafen DB';
	}//---------------------------------------------------;



	/** Get local saves, Empty Array for no saves
	 * Returns both sav + states
	 **/
	function getLocalSaves(i:Int):Array<String>
	{
		var ar:Array<String> = [];
		// Saves
		for (c in 0...2) {
			var s = Path.join(path_med_saves , ar_games[i].name + '.$c.mcr');
			if (FileTool.pathExists(s)) ar.push(s);
		}
		// States
		for (c in 0...10) {
			var s = Path.join(path_med_states, ar_games[i].name + '.mc$c');
			if (FileTool.pathExists(s)) ar.push(s);
		}
		return ar;
	}//---------------------------------------------------;

	
	/**
	   For the specified Game Index, get all the save files from the RAM DIR 
	   and return them in an array
	   @param	i
	   @return
	**/
	function getRamSaves(i:Int):Array<String>
	{
		var ar:Array<String> = [];
		if (!flag_use_altsave) return ar;
		// Saves. Memory Card (0-1)
		for (c in 0...2) {
			var s = Path.join(cfg.path_savedir, ar_games[i].name + '.$c.mcr');
			if (FileTool.pathExists(s)) ar.push(s);
		}
		// States (0-9)
		for (c in 0...10) {
			var s = Path.join(cfg.path_savedir , ar_games[i].name + '.mc$c');
			if (FileTool.pathExists(s)) ar.push(s);
		}
		return ar;
	}//---------------------------------------------------;

	/**
	   Checks the MD5 of two files
	   a and b are FULLPATHS
	**/
	function filesAreSame(a:String, b:String):Bool
	{
		return FileTool.getFileMD5(a) == FileTool.getFileMD5(b);
	}//---------------------------------------------------;


	// Launch mednafen with parameters (p)
	function startMednafen(p:String)
	{
		// Does not work on console emulators like cmder.exe
		// DEV : - Need to use "start /I" to launch withing fake terminals
		//		 - Does not work with 'execFile'
		//		 - Still, mednafen does not get the proper path? eventho the new cmd gets the path
		//		 - In windows CMD it runs perfectly

		CLIApp.quickExec('$MEDNAFEN_EXE "${p}"', cfg.path_mednafen, (s, out, err)->{
				trace(">> MEDNAFEN EXIT");
				if (mountedPath != null) {
					PismoMount.unmount(mountedPath);
				}
				if (onMednafenExit != null) onMednafenExit();
		});

	}//---------------------------------------------------;

	public function anySavesRAM():Bool { return saves_ram.length > 0; }

	public function anySavesLOCAL():Bool { return saves_local.length > 0;}

	public function getGameNames():Array<String>
	{
		var r:Array<String> = [];
		for (i in ar_games) r.push(i.name);
		return r;
	}//---------------------------------------------------;
	
	
	// For a setting ID, get the PSX.CFG value or the default (defined in SETTINGS map)
	public function setting_get(id:String):String
	{
		var value = "";	// < return value
		var fields = SETTING.get(id).split('-');
		var data:String = psxcfg.get(fields[0]);
		if (data == null) {
			value = fields[1];
		}else{
			value = data;
		}
		return value;
	}//---------------------------------------------------;
	
	// id : "special","stretch" etc. The keys in SETTING
	// val : String value as it is to be written to psx.cfg
	public function setting_set(id:String, val:String)
	{
		var fields = SETTING.get(id).split('-');
		psxcfg.set(fields[0], val);
	}//---------------------------------------------------;
	
	// After calling setting_set, call this to actually save to the file
	public function settings_save():Bool
	{
		return psxcfg.save();
	}//---------------------------------------------------;
	
	/**
	   Process the extra settings that are calculated from other fields (scaling)
	   DEV: Always called after the defaults have been loaded into 'psx.cfg'
	**/
	public function setting_process()
	{
		var sc_widen:Float = Std.parseFloat(psxcfg.data.psx.sc_widen);
		var sc_win:Float = Std.parseFloat(psxcfg.data.psx.sc_win);
		var sc_fs:Float = Std.parseFloat(psxcfg.data.psx.sc_fs);
		// Max ratio is 1.5 times the original width
		var ratio = 1 + 0.5 * sc_widen;
		psxcfg.set('psx.xscale', "" + (sc_win * ratio));
		psxcfg.set('psx.yscale', "" + sc_win);
		psxcfg.set('psx.xscalefs', "" + (sc_fs * ratio));
		psxcfg.set('psx.yscalefs', "" + sc_fs);
	}//---------------------------------------------------;
	
	/**
		Delete a GAME'S saves from the ram
	**/
	public function deleteGameSaves_fromRam()
	{
		var c = 0;
		for (i in saves_ram)
		{
			Fs.unlinkSync(i);
			trace('Deleted - $i');
			c++;
		}
		saves_ram = [];
		OPLOG = 'Deleted ($c) saves from RAM';
	}//---------------------------------------------------;
	
	/**
	   Delete all State Files (local and RAM)
	   - Used when you are finished with a game and just want the .SAV file there
	**/
	public function deleteGameStates_fromEveryWhere()
	{
		var c = 0;
		var join = saves_ram.concat(saves_local);
		for (i in join)
		{
			// Mach a single digit at the end of the string (state file format)
			if (~/(.*\d)$/i.match(i)) 
			{
				Fs.unlinkSync(i);
				trace('Deleted - $i');
				c++;
			}
		}
		OPLOG = 'Deleted ($c) STATES from RAM & LOCAL';
	}//---------------------------------------------------;
	

	static public function getConfigFullpath()
	{
		return BaseApp.app.getAppPathJoin(Engine.file_config);
	}//---------------------------------------------------;


	/**
	   Automatically called upon NPM install? Will create a new skeleton configuration file if needed
	   @return
	**/
	public static function NPM_install():Bool
	{
		var cp = Path.dirname(Sys.programPath());
		var p0 = Path.join(cp, file_config);
		var p1 = Path.join(cp, file_config_empty);

		if (!Fs.existsSync(p0))
		{
			FileTool.copyFileSync(p1, p0);
			return true;
		}

		return false;
	}//---------------------------------------------------;
	

}// --




/**
  -- THIS IS NO LONGER NEEDED, FIXED IN RECENT MEDNAFEN VERSIONS --
  ---------------------------------------------------------
	Mednafen has a bug with the cheats file.
	This copies the temp over the main file.
	Call this everytime you apply a cheat
public function fixCheats()
{
	var path_cheat_t = Path.join(path_mednafen, 'cheats', 'psx.tmpcht');
	var path_cheat = Path.join(path_mednafen, 'cheats', 'psx.cht');
	if (FileTool.pathExists(path_cheat_t)) {
		FileTool.copyFileSync(path_cheat_t, path_cheat);
		Fs.unlinkSync(path_cheat_t);
		OPLOG = "Cheat file written [OK]";
	}else {
		OPLOG = "No need to fix";
	}
}//---------------------------------------------------; */