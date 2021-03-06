#if constant(G)
inherit command;
inherit plugin_menu;
#endif

constant docstring=#"
Live code updater

In most cases, this is able to download and apply the latest Gypsum without
requiring a restart. This plugin also handles the unloading of other plugins
(and yes, it is capable of unloading itself, after which you will need to
reenable it (using the plugin configuration menu) before you can unload any
other plugins).

Plugin developers, this will be your primary tool for loading in new code.
";

constant plugin_active_by_default = 1;
int simulate; //For command-line usage, allow a "don't actually save anything" test usage

//Unzip the specified data (should be exactly what could be read from/written to a .zip file)
//and call the callback for each file, with the file name, contents, and the provided arg.
//Note that content errors will be thrown, but previously-parsed content has already been
//passed to the callback. This may be considered a feature.
//Note that this can't cope with prefixed zip data (eg a self-extracting executable).
void unzip(string data,function callback,mixed|void callback_arg)
{
	if (has_prefix(data,"PK\5\6")) return; //File begins with EOCD marker, must be empty.
	//NOTE: The CRC must be parsed as %+-4c, as Gz.crc32() returns a *signed* integer.
	while (sscanf(data,"PK\3\4%-2c%-2c%-2c%-2c%-2c%+-4c%-4c%-4c%-2c%-2c%s",
		int minver,int flags,int method,int modtime,int moddate,int crc32,
		int compsize,int uncompsize,int fnlen,int extralen,data))
	{
		string fn=data[..fnlen-1]; data=data[fnlen..]; //I can't use %-2H for these, because the two lengths come first and then the two strings. :(
		string extra=data[..extralen-1]; data=data[extralen..];
		string zip=data[..compsize-1]; data=data[compsize..];
		if (flags&8) {zip=data; data=0;} //compsize will be 0 in this case.
		string result,eos;
		switch (method)
		{
			case 0: result=zip; eos=""; break; //Stored (incompatible with flags&8 mode)
			case 8:
				#if constant(Gz)
				object infl=Gz.inflate(-15);
				result=infl->inflate(zip);
				eos=infl->end_of_stream();
				#else
				error("Gz module unavailable, cannot decompress");
				#endif
				break;
			default: error("Unknown compression method %d (%s)",method,fn); 
		}
		if (flags&8)
		{
			//The next block should be the CRC and size marker, optionally prefixed with "PK\7\b". Not sure
			//what happens if the crc32 happens to be exactly those four bytes and the header's omitted...
			if (eos[..3]=="PK\7\b") eos=eos[4..]; //Trim off the marker
			sscanf(eos,"%-4c%-4c%-4c%s",crc32,compsize,uncompsize,data);
		}
		#if __REAL__VERSION__<8.0
		//There seems to be a weird bug with Pike 7.8.866 on Windows which means that a correctly-formed ZIP
		//file will have end_of_stream() return 0 instead of "". No idea why. This is resulting in spurious
		//errors, For the moment, I'm just suppressing this error in that case.
		else if (!eos) ;
		#endif
		else if (eos!="") error("Malformed ZIP file (bad end-of-stream on %s)",fn);
		if (sizeof(result)!=uncompsize) error("Malformed ZIP file (bad file size on %s)",fn);
		#if constant(Gz)
		if (Gz.crc32(result)!=crc32) error("Malformed ZIP file (bad CRC on %s)",fn);
		#endif
		callback(fn,result,callback_arg);
	}
	if (data[..3]!="PK\1\2") error("Malformed ZIP file (bad signature)");
	//At this point, 'data' contains the central directory and the end-of-central-directory marker.
	//The EOCD contains the file comment, which may be of interest, but beyond that, we don't much care.
}

//Callbacks for 'update zip'
void data_available(object q,mapping(string:mixed) subw)
{
	if (mixed err=catch {unzip(q->data(),lambda(string fn,string data)
	{
		fn=fn[14..]; //14 == sizeof("Gypsum-master/")
		if (fn=="") return; //Ignore the first-level directory entry
		if (simulate) {++simulate; return;} //Count up the files and directories to allow simple verification
		if (fn[-1]=='/') mkdir(fn); else Stdio.write_file(fn,data);
	});}) {say(subw,"%% "+describe_error(err)); return;}
	process("all",subw);
}
void request_ok(object q,mapping(string:mixed) subw) {q->async_fetch(data_available,subw);}
void request_fail(object q,mapping(string:mixed) subw) {say(subw,"%% Failed to download latest Gypsum");}

#if constant(G)
int process(string param,mapping(string:mixed) subw)
{
	if (param=="") {say(subw,"%% Update what?"); return 1;}
	int cleanup=sscanf(param,"force %s",param); //Use "/update force some-file.pike" to clean up after building
	if (param=="git")
	{
		say(subw,"%% Attempting git-based update...");
		#ifdef __NT__
		//Note that most people on Windows won't be using git anyway - the recommended
		//installation method involves a zip installation and therefore zip updates.
		//This warning will be distinctly unusual, and anyone actually doing development
		//on Windows will simply have to use a less convenient update pattern.
		say(subw,"%% WARNING: This may not work reliably on Windows.");
		#endif
		Stdio.File stdout=Stdio.File(),stderr=Stdio.File();
		int start_time=time(1)-60;
		Process.create_process(({"git","pull","--ff-only"}),(["stdout":stdout->pipe(Stdio.PROP_IPC),"stderr":stderr->pipe(Stdio.PROP_IPC),"callback":lambda()
		{
			say(subw,"git-> "+replace(String.trim_all_whites(stdout->read()),"\n","\ngit-> "));
			say(subw,"git-> "+replace(String.trim_all_whites(stderr->read()),"\n","\ngit-> "));
			process("all",subw); //TODO: Update only those that have file_stat(f)->mtime>start_time
		}]));
		return 1;
	}
	if (param=="zip")
	{
		#if constant(Protocols.HTTP.do_async_method)
		//Note that the canonical URL is the one in the message, but Pike 7.8 doesn't follow redirects.
		Protocols.HTTP.do_async_method("GET","https://codeload.github.com/Rosuav/Gypsum/zip/master",0,0,
			Protocols.HTTP.Query()->set_callbacks(request_ok,request_fail,subw));
		say(subw,"%% Downloading https://github.com/Rosuav/Gypsum/archive/master.zip ...");
		#else
		say(subw,"%% Pike lacks HTTP engine, unable to download updates");
		#endif
		return 1;
	}
	//Update everything by updating the main routine, which then updates globals.
	//NOTE: Does NOT update persist.pike, deliberately.
	if (param=="all") param="gypsum.pike";
	if (mixed ex=catch {param=fn(param);}) {say(subw,"%% "+describe_error(ex)); return 1;}
	object self=(param!=".") && build(param); //"build ." to just rebuild what's already in queue
	//Check for anything that inherits what we just updated, and recurse.
	//The list will be built by the master object, we just need to process it (by recompiling things).
	//Note that I don't want to simply use foreach here, because the array may change.
	multiset(string) been_there_done_that=(<param>); //Don't update any file more than once. If there are circular references, stuff will be broken, but we won't infinite-loop.
	while (sizeof(G->needupdate))
	{
		[string cur,G->needupdate]=Array.shift(G->needupdate);
		//TODO: If the file no longer exists, do an unload confirm... but make sure that's safe.
		//This should then cope with renames. Kinda.
		if (!been_there_done_that[cur]) {been_there_done_that[cur]=1; build(cur);}
		else say(subw,"%% Skipping already-rebuilt file "+cur+" - possible refloop?");
	}
	if (cleanup && self) call_out(unload,.01,param,subw,self); //An update-force should do a cleanup, but let any waiting call_outs happen first.
	return 1;
}

//Attempt to unload a plugin completely, or do the cleanup after a force update.
int unload(string param,mapping(string:mixed) subw,object|void keepme)
{
	int confirm=sscanf(param,"confirm %s",param);
	if (keepme) confirm=1; //When we're doing a clean-up, always do the removal
	if (mixed ex=catch {param=fn(param);}) {say(subw,"%% "+describe_error(ex)); return 1;}
	say(subw,"%% "+param+" provides:");
	multiset(object) selfs=(<>); //Might have multiple, if there've been several versions.

	//Broken out in a vain attempt to bring some clarity to this pile of differences.
	//It might be worth unifying some of these things - for instance, always having a
	//mapping, rather than storing the object or function directly. But that would be
	//overkill in other areas... warping other code for the sake of this is backward,
	//so make changes ONLY if it's an improvement elsewhere.
	int reallydelete(object self,string desc)
	{
		if (self==keepme) say(subw,"%% (current) "+desc);
		else if (keepme) say(subw,"%% (old) "+desc);
		else say(subw,"%% "+desc);
		if (confirm && self!=keepme) return selfs[self]=1;
	};

	foreach (G->G->commands;string name;function func) if (origin(func)==param)
	{
		if (reallydelete(function_object(func),"Command: /"+name)) m_delete(G->G->commands,name);
	}
	foreach (G->G->hooks;string name;object obj) if (origin(obj)==param)
	{
		if (reallydelete(obj,"Hook: "+name)) m_delete(G->G->hooks,name);
	}
	foreach (G->G->plugin_menu;string name;mapping data) if (origin(data->self)==param)
	{
		if (reallydelete(data->self,"Menu item: "+data->menuitem->get_child()->get_text()))
			({m_delete(G->G->plugin_menu,name)->menuitem})->destroy();
	}
	foreach (G->G->windows;string name;mapping data) if (origin(data->self)==param)
	{
		//Try to show the caption of the window, if it exists.
		string desc="["+name+"]"; //Note that this also covers movablewindow and configdlg, which are special cases of window.
		if (data->mainwindow) desc=data->mainwindow->get_title(); 
		if (reallydelete(data->self,"Window: "+desc))
			if (object win=m_delete(G->G->windows,name)->mainwindow) win->destroy();
	}
	foreach (G->G->statustexts;string name;mapping data) if (origin(data->self)==param)
	{
		//Try to show the current contents (may not make sense for non-text statusbar entries)
		string desc="["+name+"]";
		catch {desc=data->lbl->get_text();};
		if (reallydelete(data->self,"Status bar: "+desc))
		{
			//Scan upward from lbl until we find the Hbox that statusbar entries get packed into.
			//If we don't find one, well, don't do anything. That shouldn't happen though.
			GTK2.Widget cur=m_delete(G->G->statustexts,name)->lbl;
			while (GTK2.Widget parent=cur->get_parent())
			{
				if (parent==G->G->windows[""]->statusbar) {cur->destroy(); break;}
				cur=parent;
			}
		}
	}
	foreach (G->G->tabstatuses;string name;object self) if (origin(self)==param)
	{
		if (reallydelete(self,"Per-tab status"))
		{
			m_delete(G->G->tabstatuses,name);
			string key="tabstatus/"+name;
			foreach (G->G->window->win->tabs,mapping subw) if (subw[key])
				m_delete(subw,key)->destroy();
		}
	}
	if (!keepme) foreach (G->globalusage;string globl;array(string) usages) if (has_value(usages,param))
	{
		//Doesn't use reallydelete() as it can't distinguish current from old (hence this whole block
		//is done only if (!keepme) ie if it's a full unload).
		say(subw,"%% Global usage: "+globl);
		if (confirm) G->globalusage[globl]-=({param});
	}
	if (confirm)
	{
		foreach (selfs;object self;) destruct(self);
		if (keepme) say(subw,"%% All old removed."); else say(subw,"%% All above removed.");
	}
	else say(subw,"%% To remove the above, type: /unload confirm "+param);
	return 1;
}

string mode = file_stat(".git") ? "git" : "zip";
constant menu_label="Update Gypsum";
void menu_clicked() {process(mode,G->G->window->current_subw());}

void create(string name)
{
	::create(name);
	set_menu_text(menu_label+" ("+mode+")");
	G->G->commands->unload=unload;
}
#else
//Stand-alone usage: '/update zip' but with minimal dependencies
//Ideally, this will work even if startup is failing.
mapping G=([]);
function say=write;
void process(string all,mapping subw) {exit(0,"Update complete [%d].\n",simulate);}
int main(int argc,array(string) argv)
{
	cd(combine_path(@explode_path(argv[0])[..<2]));
	simulate=argc>1 && argv[1]=="--simulate";
	add_constant("G",this); add_constant("persist",this); add_constant("add_gypsum_constant",add_constant);
	Protocols.HTTP.do_async_method("GET","https://codeload.github.com/Rosuav/Gypsum/zip/master",0,0,
		Protocols.HTTP.Query()->set_callbacks(request_ok,request_fail,([])));
	write("Downloading latest Gypsum...\n");
	return -1;
}
#endif
