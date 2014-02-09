inherit command;

string origin(function|object func)
{
	//Always go via the program, in case the function actually comes from an inherited parent.
	program pgm=functionp(func)?function_program(func):object_program(func);
	string def=Program.defined(pgm);
	return def && (def/":")[0]; //Assume we don't have absolute Windows paths here, which this would break
}

/**
 * Recompiles the provided plugin
 *
 * @param param The plugin to be updated
 * @param subw	The sub window which is updating the plugin
 * @return int	always returns 1
 */
int process(string param,mapping(string:mixed) subw)
{
	if (param=="") {say(subw,"%% Update what?"); return 1;}
	if (param=="git")
	{
		say(subw,"%% Attempting git-based update...");
		Stdio.File stdout=Stdio.File(),stderr=Stdio.File();
		int start_time=time(1)-60;
		Process.create_process(({"git","pull","--rebase"}),(["stdout":stdout->pipe(Stdio.PROP_IPC),"stderr":stderr->pipe(Stdio.PROP_IPC),"callback":lambda()
		{
			say(subw,"git-> "+replace(String.trim_all_whites(stdout->read()),"\n","\ngit-> "));
			say(subw,"git-> "+replace(String.trim_all_whites(stderr->read()),"\n","\ngit-> "));
			process("all",subw); //TODO: Update only those that have file_stat(f)->mtime>start_time
		}]));
		return 1;
	}
	if (param=="all")
	{
		//Update everything. Note that this uses G->bootstrap() so errors come up on the console instead of in subw.
		//NOTE: Does NOT update persist.pike or globals.pike.
		G->bootstrap("connection.pike");
		G->bootstrap("window.pike");
		G->bootstrap_all("plugins");
		say(subw,"%% Update complete.");
		param="."; //And re-update anything that needs it.
	}
	if (has_prefix(param,"/") && !has_suffix(param,".pike"))
	{
		//Allow "update /blah" to update the file where /blah is coded
		//Normally this will be "plugins/blah.pike", which just means you can omit the path and extension, but it helps with aliasing.
		function f=G->G->commands[param[1..]];
		if (!f) {say(subw,"%% Command not found: "+param[1..]+"\n"); return 1;}
		string def=origin(f);
		if (!def) {say(subw,"%% Function origin not found: "+param[1..]+"\n"); return 1;}
		param=def;
	}
	if (has_value(param,":")) sscanf(param,"%s:",param); //Turn "cmd/update.pike:4" into "cmd/update.pike". Also protects against "c:\blah".
	if (param[0]!='.') build(param); //"build ." to just rebuild what's already in queue
	//Check for anything that inherits what we just updated, and recurse.
	//The list will be built by the master object, we just need to process it (by recompiling things).
	//Note that I don't want to simply use foreach here, because the array may change.
	array(string) been_there_done_that=({param}); //Don't update any file more than once. (I'm not sure what should happen if there's circular references. Let's just hope there aren't any.)
	while (sizeof(G->needupdate))
	{
		string cur=G->needupdate[0]; G->needupdate-=({cur}); //Is there an easier way to take the first element off an array?
		if (!has_value(been_there_done_that,cur)) {been_there_done_that+=({cur}); build(cur);}
	}
	return 1;
}

//Attempt to unload a plugin completely.
//TODO: Variant form: Clean-up - search for anything that gets caught by this check but
//isn't the "current version" of the plugin (however that's to be determined...). Would
//be easy enough to do - just check if the thing that's about to be put into selfs[] is
//the same as the "current object" (again, whatever that's defined as), and ignore this
//removable if it is.
int unload(string param,mapping(string:mixed) subw)
{
	int confirm=sscanf(param,"confirm %s",param);
	//Note that you can "/unload plugins/update" but you can't "/unload /update" like
	//you can /update it. (Note also that unloading this plugin will shoot yourself in
	//the foot. Don't do it. You could recover using /x but it's fiddly. Just don't.)
	if (!file_stat(param) && file_stat(param+".pike")) param+=".pike";
	say(subw,"%% "+param+" provides:");
	multiset(object) selfs=(<>); //Might have multiple, if there've been several versions.
	foreach (G->G->commands;string name;function func) if (origin(func)==param)
	{
		selfs[function_object(func)]=1;
		say(subw,"%% Command: /"+name);
		if (confirm) m_delete(G->G->commands,name);
	}
	foreach (G->G->hooks;string name;object obj) if (origin(obj)==param)
	{
		selfs[obj]=1;
		say(subw,"%% Hook: "+name);
		if (confirm) m_delete(G->G->hooks,name);
	}
	foreach (G->G->plugin_menu;string name;mapping data) if (name && origin(data->self)==param) //Special: G->G->plugin_menu[0] is not a mapping.
	{
		selfs[data->self]=1;
		say(subw,"%% Menu item: "+data->menuitem->get_child()->get_text());
		if (confirm) ({m_delete(G->G->plugin_menu,name)->menuitem})->destroy();
	}
	foreach (G->G->windows;string name;mapping data) if (origin(data->self)==param)
	{
		selfs[data->self]=1;
		//Try to show the caption of the window, if it exists.
		string desc="["+name+"]";
		if (data->mainwindow) desc=data->mainwindow->get_title();
		say(subw,"%% Window: "+desc); //Note that this also covers movablewindow and configdlg, which are special cases of window.
		if (confirm) ({m_delete(G->G->windows,name)->mainwindow})->destroy();
	}
	foreach (G->G->statustexts;string name;mapping data) if (origin(data->self)==param)
	{
		selfs[data->self]=1;
		//Try to show the current contents (may not make sense for non-text statusbar entries)
		string desc="["+name+"]";
		catch {desc=data->lbl->get_text();};
		say(subw,"%% Status bar: "+desc);
		if (confirm)
		{
			//Scan upward from lbl until we find the Hbox that statusbar entries get packed into.
			//If we don't find one, well, don't do anything. That shouldn't happen though.
			GTK2.Widget cur=m_delete(G->G->statustexts,name)->lbl;
			while (GTK2.Widget parent=cur->get_parent())
			{
				if (parent==G->G->window->statusbar) {cur->destroy(); break;}
				cur=parent;
			}
		}
	}
	if (confirm)
	{
		foreach (selfs;object self;) destruct(self);
		say(subw,"%% All above removed.");
	}
	else say(subw,"%% To remove the above, type: /unload confirm "+param);
	return 1;
}

/**
 * Catch compilation errors and warnings and send them to the current subwindow
 *
 * @param fn 	unused
 * @param l		the line which caused the compile error.
 * @param msg	the compile error
 */
void compile_error(string fn,int l,string msg) {say(0,"Compilation error on line "+l+": "+msg+"\n");}
void compile_warning(string fn,int l,string msg) {say(0,"Compilation warning on line "+l+": "+msg+"\n");}

/**
 * Compile one pike file and let it initialize itself, similar to bootstrap()
 *
 * @param param	the pike file to be compiled.
 */
void build(string param)
{
	string param2;
	if (has_prefix(param,"globals")) sscanf(param,"%s %s",param,param2);
	if (!has_value(param,".") && !file_stat(param) && file_stat(param+".pike")) param+=".pike";
	if (!file_stat(param)) {say(0,"File not found: "+param+"\n"); return;}
	say(0,"%% Compiling "+param+"...");
	program compiled; catch {compiled=compile_file(param,this);};
	if (!compiled) {say(0,"%% Compilation failed.\n"); return 0;}
	say(0,"%% Compiled.");
	if (has_prefix(param,"globals.pike")) compiled(param,param2);
	else compiled(param);
}

void create(string name)
{
	::create(name);
	G->G->commands->unload=unload;
}
