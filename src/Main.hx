/********************************************************************
 * PSX Launcher
 * ------------
 * Main TUI class
 * Interacts with Engine
 *
 *******************************************************************/
package;

import djNode.BaseApp;
import djNode.tools.LOG;
import djTui.win.ControlsHelpBar;

import djTui.adaptors.djNode.InputObj;
import djTui.adaptors.djNode.TerminalObj;
import djTui.BaseElement;
import djTui.Styles;
import djTui.WM;
import djTui.Window;
import djTui.el.Button;
import djTui.el.Label;
import djTui.el.VList;
import djTui.win.MenuBar;
import djTui.win.MessageBox;
import haxe.Timer;

import djTui.WM.DB as DB;

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
	var wBar:MenuBar;
	var wList:Window;
	var wOpt:Window;
	var wLog:Window;
	var wInfo:Window;

	// Quick Pointers for the `Game Menu` RAMDRIVE buttons
	var btnStates:Array<Button>;
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


		if (engine.ar_games.length == 0) {
			printBanner();
			T.ptag(' - No games found in <yellow>"${engine.cfg.path_iso}"<!>\n');
			waitKeyQuit();
			return;
		}

		// -- Get size from config or parameter. Parameter can override
		parseSetSize(engine.cfg.terminal_size);
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
		wList = new Window("wList", WIDTH - 33, HEIGHT - 7);
			wList.pos(3, 3);
			wList.addStack(new Label("Available Games").setColor("green"));
			wList.addSeparator();
			// --
			var l = new VList(wList.inWidth, wList.inHeight - 2);
				l.flag_letter_jump = true;	// Pressing a letter will jump to it
				l.setData(engine.getGameNames());
				l.onSelect = (l2)->{
					l2.flag_ghost_active = true;
					openGameOptions(l2.index);
					l2.flag_ghost_active = false;
				};

			wList.addStack(l);
			wList.open(true);
			wList.listen((m, el)->{
				if (m == "escape") { /* Escape Key */
					WM.popupConfirm(()->Sys.exit(0), "QUIT");
				}
			});

		// -- Create the Game Options Window
		wOpt = new Window("wOpt", 20, 5, Styles.win.get("red.1"));
			wOpt.setPopupBehavior(); // Make it behave like a quick popup (close with esc, backspace, no tab exit)
			wOpt.posNext(wList, 2).move(0, 2);
			// --
			wOpt.addStack(new Button("b1", "Launch"));
			wOpt.addSeparator();
			btnStates = [];	// Store all the state manipulation buttons
			if (engine.flag_use_altsave) {
				wOpt.size(wOpt.width, wOpt.height + 5); // hacky way
				btnStates.push(cast wOpt.addStack(new Button("b2", "Primary --> Sec")));
				btnStates.push(cast wOpt.addStack(new Button("b3", "Sec --> Primary")));
				btnStates.push(cast wOpt.addStack(new Button("b4", "Delete all Sec").extra("?Delete all Saves from Secondary?")));
				btnStates.push(cast wOpt.addStack(new Button("b5", "Delete all States").extra("?Delete States from Sec + Primary?")));
				wOpt.addSeparator();
			}
			wOpt.addStack(new Button("", "Close").extra("close"));
			wOpt.listen(onWindowEvent_Options);

		// -- Menu Bar
		wBar = new MenuBar("wBar", 1, 3, {grid:true, bs:1});
			wBar.tab_mode = 1;
			wBar.setItems(["About", "Quit"]);
			WM.A.screen(wBar, "r", "t", 1);	// Align after setting the items, so that it has a width
			wBar.open();
			wBar.onSelect = (ind)-> {
				switch(ind){
					case 0:
						wBar.openSub( // This will resume the focused item, also will open animated
							MessageBox.create("Mednafen launcher\nCreated by JohnDimi, using Haxe", 0, null, 40),
							true);
					case 1:
						Sys.exit(0);
					default:
				}
			}

		//-- Quick popup text info, opens when a game launches
		wLog = new Window("wLog", wBar.width, 1);
			wLog.focusable = false;
			wLog.modStyle({ text:"yellow", borderStyle:0});
			wLog.addStack(new Label("", wLog.inWidth, "center").setSID("log"));
			WM.A.down(wLog, wBar, 0, 1);

		// -
		wInfo = winCreate_GameInfo();
		winCreate_HeaderFooter();

		// -- Init some other things
		engine.onMednafenExit = ()->{
			var w = DB.get('nowplay');
			if (w != null) {
				DB.remove('nowplay'); w.close();
			}
			wBar.open();
			DB["foot"].open();
			wList.open(true);
		};

		WM.onWindowFocus = (w)->{

		};

		//-- Test footer --

	}//---------------------------------------------------;


	// - Open the Game Options Popup for a target INDEX
	// - It first checks the status of the buttons, then opens the window
	function openGameOptions(i:Int)
	{
		engine.prepareGame(i);
		// Only bother with checking if RAMDRIVE is enabled
		if (engine.flag_use_altsave) {
			btnStates[0].disabled = !engine.anySavesLOCAL();
			btnStates[1].disabled = !engine.anySavesRAM();
			btnStates[2].disabled = btnStates[1].disabled;
			btnStates[3].disabled = btnStates[0].disabled && btnStates[1].disabled;
		}
		DB.get('wOpt').open(true);
	}//---------------------------------------------------;


	// Window Events listener for the Game Options Window
	function onWindowEvent_Options(a:String, b:BaseElement)
	{
		function opEnd() {
			// Repoen the same, to recheck button status
			openGameOptions(engine.index);
			// Show the previous operation LOG
			if (engine.OPLOG != null) {
				openLogStatus(engine.OPLOG);
			}
		}

		// ------

		if (a == "close")
		{
			wInfo.close();
			wList.focus();	// It will call this after the window is closed, but it's ok

		} else if (a == "open")
		{
			openGameInfo();

		}else if (a == "fire") switch (b.SID)
		{
			case "b1":	// Launch game

				// Close all the windows
				DB["foot"].close();
				wOpt.close(); wList.close(); wBar.close();

				if (!engine.launchGame()) {
					openLogStatus(engine.ERROR);
					return;
				}
				var mb = MessageBox.create("Now Playing:\n" + engine.current.name , -1, null, 40, Styles.win.get("gray.1"));
				DB.set('nowplay', mb);
				mb.open(true);

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
	function winCreate_GameInfo():Window
	{
		var w = new Window( -1, 2, Styles.win.get('black.1'));
		w.padding(2, 0);
		w.borderStyle = 0;

			inf_name = new Label("", w.inWidth - 13);
			inf_name.setColor("yellow");

		w.addStackInline([new Label("Game Name : "), inf_name]);
		w.focusable = false;
		WM.A.down(w, wList);

		inf_RAM = new Button("", "   ", 1);
		inf_LOCAL = new Button("", "   ", 1);
		inf_ZIP = cast new Label("").setColor("cyan");

		w.addStackInline([
			new Label("Save Secondary"), inf_RAM,
			new Label("Save Primary"), inf_LOCAL, inf_ZIP]);
		return w;
	}//---------------------------------------------------;

	// - Sub Function
	// Creates and adds a header/footer to the TUI
	function winCreate_HeaderFooter()
	{
		// -- Header Footer
		// : Header
		var head = new Window( -1, 1);
			head.focusable = false;
			// By default all windows use the default `WM.global_style_win`
			head.modStyle({
				bg:"darkcyan", text:"black", borderStyle:0, borderColor:{fg:"darkblue"}
			});
			head.padding(2, 0);
			head.addStack(new Label(PROGRAM_INFO.name + " v" + PROGRAM_INFO.version));


		// : New footer
		var foot = new ControlsHelpBar();
			foot.setData('Nav:←↑→↓|Select:Enter|Focus:Tab|Back:Esc|Quit:^c');
			foot.pos(0, HEIGHT - 1);
			DB.set("foot", foot);	// Because I want to hide/unhide this

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
		var l:Label = cast wLog.getElIndex(1);
			l.text = s;
			wLog.open();
		if (winTimer != null) {
			winTimer.stop();
			winTimer = null;
		}
		winTimer = Timer.delay(function(){
			wLog.close();
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

		wInfo.open();
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
