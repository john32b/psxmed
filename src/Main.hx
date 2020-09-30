package;
import djNode.BaseApp;
import djNode.tools.LOG;
import djTui.BaseElement;
import djTui.Styles;
import djTui.WM;
import djTui.Window;
import djTui.adaptors.djNode.InputObj;
import djTui.adaptors.djNode.TerminalObj;
import djTui.el.Button;
import djTui.el.Label;
import djTui.el.VList;
import djTui.win.MenuBar;
import djTui.win.MessageBox;
import haxe.Timer;


/**
 * PSX Launcher
 * ------------
 * Main TUI class
 * - Interacts with Engine
 */
class Main extends BaseApp
{
	// Standard program entry
	static public function main() { new Main(); }

	static var WIDTH = 80;
	static var HEIGHT = 25;
	static var WIDTH_MIN = 60;
	static var HEIGHT_MIN = 20;
	static var STATUS_POPUP_TIME:Int = 3000;

	// Instance for the app engine
	var engine:Engine;

	// Hold the windows
	var winOptions:Window;
	var winList:Window;
	var winInfo:Window;
	var winLog:Window;

	// Quick Pointers for the `Game Menu` RAMDRIVE buttons
	var winOptBtns:Array<Button>;


	var winNowPlaying:Window;

	//====================================================;

	// --
	override function init()
	{
		PROGRAM_INFO = {
			name:Engine.NAME,
			version:Engine.VER,
			author:"JohnDimi"
		};

		ARGS.Actions = [
			['cfg', "Opens the config file with the associated OS editor"],
			['install', "-Called by the NPM installer to create the config file"]
		];

		ARGS.Options = [
			['size', 'Set rendering area size. "WIDTH,HEIGHT" or "full" to use the full window area\ne.g. -size 80,20 | -size full', '1']
		];

		FLAG_USE_SLASH_FOR_OPTION = false;

		#if debug
			LOG.pipeTrace(); // all traces will redirect to LOG object
			LOG.setLogFile("a:\\psxlaunch_log.txt");
		#end

		super.init();
	}//---------------------------------------------------;

	// Hack for real terminals. Put the cursor at the end of the
	override function onExit(code:Int)
	{
		if (code == 0 && WM._isInited) T.move(0, WM.height + 1);
		super.onExit(code);
	}//---------------------------------------------------;

	// --
	// User Main entry ::
	override function onStart()
	{
		// -- Called when getting installed by NPM
		if (argsAction == "install") {
			if (Engine.NPM_install()) {
				T.print("- Created empty config file OK");
			}else{
				T.print("- Config file already exists from previous installation. Leaving as is.");
			}
			return;
		}//------

		// - First check this now, before creating the engine
		if (argsAction == "cfg") {
			T.ptag('Opening configuration file...');
			Sys.command('start ${Engine.getConfigFullpath()}');
			return;
		}//------

		// -- Create the Main Engine
		engine = new Engine();
		if (!engine.init()) {
			printBanner();
			T.ptag('\n <red>INIT ERROR : <!>${engine.ERROR}');
			T.ptag('\n <yellow>Settings file : <!>' + Engine.getConfigFullpath());
			T.ptag('\n You can also run <yellow>psxmed cfg<!> to open the config file');
			T.endl();
			waitKeyQuit();
			return;
		}//------


		if (engine.list_games.length == 0) {
			printBanner();
			T.ptag(' - No games found in <yellow>"${engine.path_isos}"<!>\n');
			waitKeyQuit();
			return;
		}

		// -- Get size from config or parameter. Parameter can override
		parseSetSize(engine.terminal_size);
		if (argsOptions.size != null) {
			if (argsOptions.size == "full") {
				WIDTH = T.getWidth();
				HEIGHT = T.getHeight();
			}else{
				parseSetSize(argsOptions.size);
			}
		}//------

		// -- Initialize TUI:
		T.setTitle(Engine.NAME);
		T.resizeTerminal(WIDTH, HEIGHT);
		T.pageDown(); T.clearScreen(); T.cursorHide();
		WM.create( new InputObj(), new TerminalObj(), WIDTH, HEIGHT, "black.1", "blue.1");

		// -- Main window Listing all games
		winList = new Window("main", WIDTH - 25 - 4 - 4, HEIGHT - 7);
			winList.pos(3, 3);
			winList.addStack(new Label("Available Games").setColor("green"));
			winList.addSeparator();
			// --
			var l = new VList(winList.inWidth, winList.inHeight - 2);
				l.setData(engine.list_names);
				l.onSelect = onGameSelect;
				l.flag_letter_jump = true;	// Pressing a letter will jump to it
			winList.addStack(l);
			winList.open(true);
			winList.listen((m, el)->{
				if (m == "escape") { /* Escape Key */
					WM.popupConfirm(()->Sys.exit(0), "QUIT");
				}
			});

		// -
		create_header_footer();
		create_info();

		// -- Game Options
		winOptions = new Window("options", 20, 5, Styles.win.get("red.1"));
			winOptions.posNext(winList, 2).move(0, 2);
			winOptions.setPopupBehavior(); // Make it behave like a quick popup
			winOptions.addStack(new Button("b1", "Launch"));
			winOptions.addSeparator();

			winOptBtns = [];
			if (engine.flag_use_ramdrive)
			{
				winOptions.size(winOptions.width, winOptions.height + 5); // hacky way
				winOptBtns.push(cast winOptions.addStack(new Button("b2", "Local --> RAM")));
				winOptBtns.push(cast winOptions.addStack(new Button("b3", "RAM --> Local")));
				winOptBtns.push(cast winOptions.addStack(new Button("b4", "Delete all RAM").extra("?Delete all Saves from RAM?")));
				winOptBtns.push(cast winOptions.addStack(new Button("b5", "Delete all States").extra("?Delete States from RAM + LOCAL?")));
				winOptions.addSeparator();
			}

			winOptions.addStack(new Button("", "Close").extra("close"));
			winOptions.listen(onWindowEvent_Options);

		// -- Menu Bar
		var w2 = new MenuBar(1, 3, {grid:true, bs:1});
			w2.setItems(["FixCheats", "About", "Quit"]);
			WM.A.screen(w2, "r", "t", 1);
			w2.open();
			w2.flag_lock_focus = false;
			w2.onSelect = (ind)-> {
				switch(ind){
					case 0:
						engine.fixCheats();
						openLogStatus(engine.OPLOG);
					case 1:

						w2.flag_return_focus_once = true;
						MessageBox.create("Mednafen launcher\nCreated by JohnDimi, using Haxe", 3, null, 40, true);
					case 2:
						Sys.exit(0);
					default:
				}
			}

		//-- Quick popup text info, opens when a game launches
		winLog = new Window(w2.width, 1);
		winLog.flag_focusable = false;
		winLog.padding(0, 0);
		winLog.modStyle({ text:"yellow", borderStyle:0});
		winLog.addStack(new Label("", winLog.inWidth, "center").setSID("log"));
		WM.A.down(winLog, w2, 0, 1);

		// -- Init some other things
		engine.onMednafenExit = ()->{
			if (winNowPlaying != null) { winNowPlaying.close(); winNowPlaying = null; }
			winList.open(true);
		};
	}//---------------------------------------------------;


	// --
	// From the main window, a game was clicked
	// - Open the game options window
	function onGameSelect(i:Int)
	{
		engine.prepareGame(i);
		// Only bother with checking if RAMDRIVE is enabled
		if (engine.flag_use_ramdrive) {
			winOptBtns[0].disabled = !engine.anySavesLOCAL();
			winOptBtns[1].disabled = !engine.anySavesRAM();
			winOptBtns[2].disabled = winOptBtns[1].disabled;
			winOptBtns[3].disabled = winOptBtns[0].disabled && winOptBtns[1].disabled;
		}
		winOptions.open(true);
	}//---------------------------------------------------;


	// Window Events listener for the Game Options Window
	function onWindowEvent_Options(a:String, b:BaseElement)
	{
		function opEnd()
		{
			// Repoen the same, to recheck button status
			onGameSelect(engine.index);

			// Show the previous operation LOG
			if (engine.OPLOG != null)
			{
				openLogStatus(engine.OPLOG);
			}
		}

		if (a == "close")
		{
			winInfo.close();
			winList.focus();
		}else
		if (a == "open")
		{
			openGameInfo();
		}else
		if (a == "fire") switch (b.SID)
		{
			case "b1":

				winOptions.close();

				if (!engine.launchGame())
				{
					openLogStatus(engine.ERROR);
					return;
				}

				winList.close();
				winNowPlaying = MessageBox.create("Now Playing:\n" + engine.gameName , 3, null, 40, Styles.win.get("gray.1"));

			case "b2":
				engine.copySave_LocalToRam();
				opEnd();
			case "b3":
				engine.copySave_RamToLocal();
				opEnd();
			case "b4":
				engine.deleteGameSaves_fromRam();
				opEnd();
			case "b5":
				engine.deleteGameStates_fromEveryWhere();
				opEnd();
			default:

		}
	}//---------------------------------------------------;




	// - Sub Function
	// - Create and add info window (Small banner text on game information below main window)
	var inf_name:Label;
	var inf_RAM:Button;
	var inf_LOCAL:Button;
	var inf_ZIP:Label;
	function create_info()
	{
		winInfo = new Window( -1, 2, Styles.win.get('black.1'));
		winInfo.padding(2, 0);
		winInfo.borderStyle = 0;

			inf_name = new Label("", winInfo.inWidth - 13);
			inf_name.setColor("yellow");

		winInfo.addStackInline([new Label("Game Name : "), inf_name]);
		winInfo.flag_focusable = false;
		WM.A.down(winInfo, winList);

		inf_RAM = new Button("", "   ", 1);
		inf_LOCAL = new Button("", "   ", 1);
		inf_ZIP = cast new Label("").setColor("cyan");

		winInfo.addStackInline([
			new Label("Save on RAM"), inf_RAM,
			new Label("Save Local"), inf_LOCAL, inf_ZIP]);
	}//---------------------------------------------------;

	// - Sub Function
	// Creates and adds a header/footer to the TUI
	function create_header_footer()
	{
		// -- Header Footer
		// : Header
		var head = new Window( -1, 1);
			head.flag_focusable = false;
			// By default all windows use the default `WM.global_style_win`
			head.modStyle({
				bg:"darkcyan", text:"black", borderStyle:0, borderColor:{fg:"darkblue"}
			});
			head.padding(2, 0);
			head.addStack(new Label(PROGRAM_INFO.name + " v" + PROGRAM_INFO.version));

		// : Footer
		var foot = new Window( -1, 1);
			foot.flag_focusable = false;
			foot.padding(0);
			foot.modStyle({
				bg:"gray", text:"darkblue", borderStyle:0
			});
			foot.addStack(new Label("[TAB] = FOCUS | [↑↓] = MOVE | [ENTER] = SELECT | [ESC] = BACK", foot.inWidth, "center"));
			foot.pos(0, WM.height - foot.height);

		WM.add(head);
		WM.add(foot);
	}//---------------------------------------------------;
	/**
	   Show a quick status popup. General Purpose
	   @param	s Message
	**/
	var winTimer:Timer;
	function openLogStatus(s:String)
	{
		var l:Label = cast winLog.getElIndex(1);
			l.text = s;
			winLog.open();
		if (winTimer != null) {
			winTimer.stop();
			winTimer = null;
		}
		winTimer = Timer.delay(function(){
			winLog.close();
		}, STATUS_POPUP_TIME);
	}//---------------------------------------------------;


	/** Open game info with current prepared games */
	function openGameInfo()
	{
		inf_name.text = engine.current.name + "     ";

		if (inf_name.text.length > inf_name.width)
			inf_name.scroll(125);
		else
			inf_name.stop();

		if (engine.saves_ram.length > 0){
			inf_RAM.text = "YES";
			inf_RAM.colorIdle("green");
		}
		else{
			inf_RAM.text = "NO";
			inf_RAM.colorIdle("red");
		}
		if (engine.saves_local.length > 0){
			inf_LOCAL.text = "YES";
			inf_LOCAL.colorIdle("green");
		}
		else{
			inf_LOCAL.text = "NO";
			inf_LOCAL.colorIdle("red");
		}

		if (engine.isZIP){
			inf_ZIP.text = "(zipped)";
		}else{
			inf_ZIP.text = "";
		}

		winInfo.open();
	}//---------------------------------------------------;


	// Set the Width/Height from a string like "80,20"
	function parseSetSize(strval:String)
	{
		var s = cast(strval, String).split(',');
		if (s != null && s.length == 2) {
			WIDTH = cast Math.max(Std.parseInt(s[0]), WIDTH_MIN);
			HEIGHT = cast Math.max(Std.parseInt(s[1]), HEIGHT_MIN);
		}else{
			throw "Cannot read Size from " + strval;
		}
	}//---------------------------------------------------;


}//-- end class --
