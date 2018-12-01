package;

import djNode.tools.FileTool;
import djNode.utils.CLIApp;
import djNode.utils.ProcUtil;
import haxe.crypto.Md5;
import hxconf.ConfigFile;
import js.Node;
import js.node.ChildProcess;
import js.node.Fs;
import js.node.Os;
import js.node.Path;
import js.node.Process;
import sys.io.File;


	
typedef GameEntry = {
	var name:String;
	var path:String;
};
	
/**
 * ...
 */
class Engine 
{
	// Search for these type of files when scanning
	static var extensionsToSearch = ["cue", "m3u", "zip"];
	static var file_config = "config.ini";
	static var MEDNAFEN_EXE = "mednafen.exe";
	static var PSIMO_EXE = "PFM.exe";
	
	// -- Read from `CONFIG` file:
	public var path_isos:String;
	public var path_mednafen:String;
	public var path_ramdrive:String;
	public var path_autorun:String;
	public var setting_autosave:Bool;
	
	// --
	public var flag_use_ramdrive(default, null):Bool = false;
	
	// The Names of the games (filenames)
	public var list_games:Array<GameEntry>;
	// -- fake
	public var list_names(get, null):Array<String>;
	function get_list_names(){
		var r:Array<String> = [];
		for (i in list_games) r.push(i.name);
		return r;
	}
	
	// Read this error in case of fatal exit
	public var ERROR:String;
	// Read this to get operations LOG
	public var OPLOG:String;
	
	// -- Working with one game at a time
	// Prepared game:
	
	public var current:GameEntry;
	public var index:Int = -1;
	public var saves_local:Array<String>; // Fullpath of all LOCAL saves (states+MCR)
	public var saves_ram:Array<String>;   // Fullpath of all RAM saves   (states+MCR)
	
	/** Current game name */
	public var gameName(get, null):String;
	function get_gameName() {return list_games[index].name; }	
	
	// Called automatically
	public var onMednafenExit:Void->Void;
	
	// If a game needs to be mounted (zip) this will hold the game fill path.
	// so that it can be unmounted later. It checks for null to figure out mounted game or not.
	var mountedPath:String = null;
	// Current selected game is zip or not
	public var isZIP:Bool;
	
	//====================================================;
	
	
	public function new() 
	{
	}//---------------------------------------------------;
	
	
	
	public function init():Bool
	{
		try{
			loadSettingsFile();
			scanDirectories();
			if (list_games.length == 0) throw "Did not find any games";
			checkAutorun();
			
		}catch (e:String)
		{
			ERROR = e;
			return false;
		}
		return true;
	}
	
	
	public function anySavesRAM():Bool { return saves_ram.length > 0;}
	public function anySavesLOCAL():Bool { return saves_local.length > 0;}
	

	/**  Loads `CONFIG` file and populates variables
	     Also checks for paths in config file if valid
		 ! THROWS string errors
	**/
	function loadSettingsFile()
	{
		var ini = new ConfigFile();
		ini.read(Fs.readFileSync(Path.join(Path.dirname(Node.process.argv[1]), file_config), {encoding: "utf8"}));			
		
		var cfg = ini.getAll("settings");
		path_isos = Path.normalize( cfg.get("isos") );
		path_mednafen = Path.normalize( cfg.get("mednafen") );
		path_ramdrive = Path.normalize( cfg.get("ramdrive") );
		path_autorun  = Path.normalize( cfg.get("autorun") );
		setting_autosave = Std.parseInt(cfg.get("autosave") ) == 1;
		
		//-- Checks
		
		if (!FileTool.pathExists(path_isos))
		{
			throw 'ISOPATH `$path_isos` does not exist';
		}
		
		if (!FileTool.pathExists(path_mednafen))
		{
			throw 'MEDNAFEN PATH `$path_mednafen` does not exist';
		}	
		
		if (!FileTool.pathExists(Path.join(path_mednafen,MEDNAFEN_EXE)))
		{
			throw 'Can\'t find "$MEDNAFEN_EXE" in "${path_mednafen}"';
		}	
		
		if (flag_use_ramdrive = (path_ramdrive.length > 1))
		{
			FileTool.createRecursiveDir(path_ramdrive);
		}
	
		trace("Engine : Loading Settings ::");
		trace(' - Path Isos : ${path_isos}');
		trace(' - Path Mednafen : ${path_mednafen}');
		trace(' - Path RAMDRIVE : ${path_ramdrive}');
		trace(' - Path Autorun : ${path_autorun}');
		trace(' - FLAG Autosave : ${setting_autosave}');
		trace(' - FLAG Use RAM : ${flag_use_ramdrive}');
		trace(' -------- ');
		
	}//---------------------------------------------------;
	
	
	/**
	   : Scans path for games and fills vars
	   
	   : DEV
		- Scans all valid extension game files, adds entry to `list_games`
		- THEN Scans all M3U files and deletes duplicates from the main `list_games`
		- Alphabetize the end array
	**/
	function scanDirectories()
	{
		list_games = [];
		
		var m3u:Array<String> = [];
		var l = FileTool.getFileListFromDirR(path_isos, extensionsToSearch);

		
		for (i in l)
		{
			var entry = {
				name : Path.basename(i, Path.extname(i)),
				path : i
			};
			
			list_games.push(entry);	
			
			if (FileTool.getFileExt(i) == "m3u") m3u.push(i);
		}
		
		// Open the M3U files and remove their entries from the main DB
		for (i in m3u)
		{
			var files = Fs.readFileSync(i).toString().split(Os.EOL);
			
			for (ii in files)
			{
				// I can delete in a loop as long as it's in reverse [OK]
				var x = list_games.length;
				while (--x >= 0)
				{
					if (list_games[x].name == Path.basename(ii, Path.extname(ii)))
					{
						list_games.splice(x, 1);
					}
				}
			}
		}
		
		//-- Alphabetize the rezults?
		list_games.sort(function(a, b) {
			return a.name.toLowerCase().charCodeAt(0) - b.name.toLowerCase().charCodeAt(0);
		});
		
		trace('-> Number of games found : [${list_games.length}]');
		
		#if debug
			for (g in list_games) {
				trace('  - ${g.name} ,${g.path} ');
			}
		#end
	}//---------------------------------------------------;
	
	/**
		PRE: A Game is prepared
	**/
	public function launchGame():Bool
	{
		var g = list_games[index];
		
		trace('Launching game : ${g.name}');
		
		/// NEW: Mount the game if it is a zip game
		
		if (isZIP)
		{
			// Mount the .zip then launch
			mountedPath = mount_zip(g.path);
			
			// - Figure out what kind of files are there in the archive
			// - Prefer M3u files over .Cue files
			
			var l:String = null; // File to launch
			for (f in FileTool.getFileListFromDir(mountedPath))
			{
				var ext = FileTool.getFileExt(f);
				
				if (ext == "cue")
				{
					l = f;
				} else 
				
				if (ext == "m3u")
				{
					l = f; break; // Break because it should only have one .m3u file
				}
			}
			
			if (l == null)
			{
				ERROR = "Archive Error.";
				unmount(mountedPath);
				return false;
			}
			
			startMednafen(Path.join(mountedPath, l));
			
		}else
		{
			// Normal .cue/.m3u game, Launch normally
			mountedPath = null;
			startMednafen(g.path);
		}

		return true;
	}//---------------------------------------------------;
	
	
	function startMednafen(p:String)
	{
		// Does not work on console emulators like cmder.exe
		// #DEVNOTE: need to use "start /I" to launch withing fake terminals
		//			 -Does not work with 'execFile'
		var p = ChildProcess.exec('START /I $MEDNAFEN_EXE "${p}"', {
				cwd:path_mednafen
			},
			function(a,b,c){
				trace("-- MEDNAFEN EXIT --");
				if (mountedPath != null) {
					unmount(mountedPath);
				}
				if (onMednafenExit != null) onMednafenExit();
			});		
	}//---------------------------------------------------;
	
	/**
	   Save Exists locally and ramdrive Exists
	   Does not re-alter VARS, you need to prepare game again later
	   @OPLOG
	**/
	public function copySave_LocalToRam()
	{
		if (saves_local.length == 0) return; // Just in case
		
		var numCopied:Int = 0;
		var numTotal:Int = saves_local.length;
		
		for (i in saves_local)
		{
			var newsave = Path.join(path_ramdrive, Path.basename(i));
			// Don't copy over
			if (FileTool.pathExists(newsave))
			{
				trace('$newsave - Already exists - [SKIP]');
			}else
			{
				FileTool.copyFile(i, newsave); 
				numCopied++;
				trace('$newsave - Copied to RAM - [OK]');
			}
		}
		
		OPLOG = 'Copied ($numCopied/$numTotal) saves to RAM';
	}//---------------------------------------------------;
	
	/**
	   Copy RAM to LOCAL and overwrite everything
	   Does not re-alter VARS, you need to prepare game again later
	   @OPLOG
	**/
	public function copySave_RamToLocal()
	{
		if (saves_ram.length == 0) return; // Just in case
		
		var numCopied:Int = 0;
		var numTotal:Int = saves_ram.length;

		for (i in saves_ram)
		{
			var dest:String;
			if (FileTool.getFileExt(i) == "mcr")
			{
				dest = Path.join(path_mednafen, 'sav', Path.basename(i));
			}else
			{
				dest = Path.join(path_mednafen, 'mcs', Path.basename(i));
			}
			
			// Check if file is the same, don't overwrite same files
			// NOTE, dest could not exist yet
			if (FileTool.pathExists(dest) && filesAreSame(i, dest) )
			{
				trace('$dest - already exists with same contents, [SKIPPING]');	
			}
			else
			{
				FileTool.copyFile(i, dest);
				trace('$dest - Copied to LOCAL - [OK]');
				numCopied++;
			}
			
		}
		OPLOG = 'Copied ($numCopied/$numTotal) saves to LOCAL';
	}//---------------------------------------------------;
	
	/**
		Delete a GAME'S saves from the ram
	*/
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
			if (~/(.*\d)$/i.match(i)) // Mach a single digit at the end of the string
			{
				Fs.unlinkSync(i);
				trace('Deleted - $i');
				c++;
			}
		}
		OPLOG = 'Deleted ($c) STATES from RAM & LOCAL';
	}//---------------------------------------------------;
	
	
	/**
	   Delete ALL GAMES save data from RAM.
	   Empty the RAMDRIVE OUT.
	**/
	public function deleteEverything_fromRam()
	{
	}//---------------------------------------------------;
	


	/** Get local saves, Empty Array for no saves
	 * Returns both sav + states
	 **/
	public function getLocalSaves(i:Int):Array<String>
	{
		var ar:Array<String> = [];
		for (c in 0...2)
		{
			var s = Path.join(path_mednafen , "sav" , list_games[i].name + '.$c.mcr');
			if (FileTool.pathExists(s)) ar.push(s);
		}
		for (c in 0...10)
		{
			var s = Path.join(path_mednafen , "mcs", list_games[i].name + '.mc$c');
			if (FileTool.pathExists(s)) ar.push(s);
		}
		return ar;
	}//---------------------------------------------------;
	
	
	public function getRamSaves(i:Int):Array<String>
	{
		var ar:Array<String> = [];
		if (!flag_use_ramdrive) return ar;
		
		for (c in 0...2)
		{
			var s = Path.join(path_ramdrive, list_games[i].name + '.$c.mcr');
			if (FileTool.pathExists(s)) ar.push(s);
		}
		for (c in 0...10)
		{
			var s = Path.join(path_ramdrive , list_games[i].name + '.mc$c');
			if (FileTool.pathExists(s)) ar.push(s);
		}
		return ar;
	}
	

	/**
	   Request a game index to be prepared to be launched
	   Called when you select a game from the list and the options are displayed
	   @param	i
	**/
	public function prepareGame(i:Int)
	{
		index = i;
		current = list_games[index];
		trace("Preparing Game: " + current.name);
		saves_local = getLocalSaves(i);
		saves_ram = getRamSaves(i);
		isZIP = current.path.indexOf('.zip') == current.path.length - 4;
	}
	
	/**
		Mednafen has a bug with the cheats file.
		This copies the temp over the main file.
		Call this everytime you apply a cheat
	**/
	public function fixCheats()
	{
		var path_cheat_t = Path.join(path_mednafen, 'cheats', 'psx.tmpcht');
		var path_cheat = Path.join(path_mednafen, 'cheats', 'psx.cht');
		
		if (FileTool.pathExists(path_cheat_t))
		{
			FileTool.copyFile(path_cheat_t, path_cheat);
			Fs.unlinkSync(path_cheat_t);
			OPLOG = "Cheat file written [OK]";
		}else
		{
			OPLOG = "No Need.";
		}
	}
	
	/**
	   Checks if an autorun is set, checks if the process is already running, and starts it if not.
	**/
	public function checkAutorun()
	{
		trace("-> Checking autorun program .");
		if (path_autorun.length == 0) 
		{
			trace("Autorun not set");
			return;
		}
		
		var exe = Path.basename(path_autorun);
		
		var r = ProcUtil.getTaskPIDs(exe);
		if (r.length == 0)
		{
			var p = ChildProcess.exec('START /I $path_autorun', function(a, b, c){});	
			OPLOG = 'Launched "$exe" [OK]';
		}else{
			OPLOG = '"$exe" Already running';
		}
		
		trace(OPLOG);
	}//---------------------------------------------------;
	

	/** Prints some infos about current state */
	public function info()
	{
		trace("-- ENGINE INFO ----- ");
		trace("NUMBER OF GAMES", list_games.length);
		if(index>=0) trace("CURRENT ACTIVE", list_games[index].name);
		trace("LOCAL SAVES ::", saves_local);
		trace("RAM SAVES ::", saves_ram);
	}//---------------------------------------------------;
		
	/**
	   Checks the MD5 of two files
	   a and b are FULLPATHS
	**/
	function filesAreSame(a:String, b:String):Bool
	{
		return FileTool.getFileMD5(a) == FileTool.getFileMD5(b);
	}//---------------------------------------------------;
	
	/**
	   Mounts a zip and returns the path it was mounted
	   @param	p Path of zip
	   @return
	**/
	function mount_zip(p:String):String
	{
		try{
			ChildProcess.execSync('${PSIMO_EXE} mount "$p"');
		}catch (e:Dynamic)
		{
			// Already Mounted
		}
		
		var res = ChildProcess.execSync('${PSIMO_EXE} list "$p"');
		var reg = ~/.*\.zip (.*)/ig;
		if (reg.match(res))
		{
			return reg.matched(1);
		}else
		{
			return null;
		}
	}
	
	/**
	   Unmounts a mounted zip
	   @param	p Either the Mounted path or Source Zip file
	**/
	function unmount(p:String)
	{
		try{
			ChildProcess.execSync('${PSIMO_EXE} unmount "$p"');
		}catch (e:Dynamic)
		{
			// Already UNMounted
		}
	}
	
	
}// -