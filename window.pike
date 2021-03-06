//GUI handler.
inherit statustext_maxwidth;
inherit movablewindow;
constant is_subwindow=0;

constant colnames=({"black","red","green","orange","blue","magenta","cyan","white"});
constant enumcolors=sprintf("%2d: ",enumerate(16)[*])[*]+(colnames+("bold "+colnames[*]))[*]; //Non-bold, then bold, of the same names, all prefixed with numbers.
constant default_ts_fmt="%Y-%m-%d %H:%M:%S UTC";
array(GTK2.GdkColor) colors; //Convenience alias for win->colors - also used externally but not pledged

mapping(string:mapping(string:mixed)) channels=persist->setdefault("color/channels",([]));
constant deffont="Monospace 10";
mapping(string:mapping(string:mixed)) fonts=persist->setdefault("window/font",(["display":(["name":deffont]),"input":(["name":deffont])]));
mapping(string:mapping(string:mixed)) numpadnav=persist->setdefault("window/numpadnav",([])); //Technically doesn't have to be restricted to numpad.
multiset(string) numpadspecial=persist["window/numpadspecial"] || (<"look", "glance", "l", "gl">); //Commands that don't get prefixed with 'go ' in numpadnav
mapping(string:object) fontdesc=([]); //Cache of PangoFontDescription objects, for convenience (pruned on any font change even if something else was using it)
GTK2.Window mainwindow; //Convenience alias for win->mainwindow - also used externally
int paused; //Not saved across reloads
mapping(GTK2.MenuItem:string) menu=([]); //Retain menu items and the names of their callback functions

int monochrome; //Not saved into G, but retrieved on reload
array(GTK2.PangoTabArray) tabstops;
constant pausedmsg="<PAUSED>"; //Text used on status bar when paused; "" is used when not paused.
constant pos_key="window/winpos";
constant load_size=1;
mapping(string:mixed) mainwin; //Set equal to win[] and thus available to nested classes
mapping(string:GTK2.Menu) menus=([]); //Maps keyword to menu, eg "file" to the submenu contained inside the _File menu. Adding something to menu->file adds it to the File menu.

//Default set of worlds. Note that new worlds added to this list will never be auto-added to existing config files, due to the setdefault.
//It may be worth having some means of marking new worlds to be added. Or maybe have a way to recreate a lost world from the template??
mapping(string:mapping(string:mixed)) worlds=persist->setdefault("worlds",([
	"threshold":(["host":"thresholdrpg.com","port":23,"name":"Threshold RPG","descr":"Threshold RPG by Frogdice, a high-fantasy game with roleplaying required."]),
	"minstrelhall":(["host":"gideon.rosuav.com","port":221,"name":"Minstrel Hall","descr":"A virtual gaming shop where players gather to play Dungeons & Dragons online."]),
]));

mapping(string:mapping(string:mixed)) highlightkeywords=persist->setdefault("window/highlight",([]));

/* I could easily add tab completion to the entry field. The only question is, what
should be added as suggestions?
1) Character names. Somehow it should figure out who's a character and who's not.
2) Objects in rooms that can be looked at.
3) Channel names, and then people on those channels
4) Other?
5) Local commands, if the user's already typed a slash. Should be easy enough.

Should it be context sensitive? It could be reconfigured in subw_ef_changed().
*/

/* Each subwindow is defined with a mapping(string:mixed) - some useful elements are:

	//Each 'line' represents one line that came from the MUD. In theory, they might be wrapped for display, which would
	//mean taking up more than one display line, though currently this is not implemented.
	//Each entry must begin with a metadata mapping and then alternate between color and string, in that order.
	array(array(mapping|int|string)) lines=({ });
	array(mapping|int|string) prompt=({([])}); //NOTE: If this is ever reassigned, other than completely overwriting it, check pseudo-prompt handling (in connection.pike).
	GTK2.DrawingArea display;
	GTK2.ScrolledWindow maindisplay;
	GTK2.Adjustment scr;
	GTK2.Entry ef;
	GTK2.Widget page;
	array(string) cmdhist=({ });
	int histpos=-1;
	int passwordmode; //When 1, commands won't be saved.
	int lineheight; //Pixel height of a line of text
	int totheight; //Current height of the display
	mapping connection;
	string tabtext;
	int activity=0; //Set to 1 when there's activity, set to 0 when focus is on this tab
	array(object) signals; //Collection of gtksignal objects - replaced after code reload
	int selstartline,selstartcol,selendline,selendcol; //Highlight start/end positions. If no highlight, selstartline will not even exist.
*/
//Note that this is called from other files, eg when a new passive-mode connection is established, hence the parameterization of txt.
mapping(string:mixed) subwindow(string txt)
{
	mapping(string:mixed) subw=(["lines":({ }),"prompt":({([])}),"cmdhist":({ }),"histpos":-1]);
	win->tabs+=({subw});
	//Build the subwindow
	win->notebook->append_page(subw->page=GTK2.Vbox(0,0)
		->add(GTK2.Hbox(0,0)
			->add(subw->maindisplay=GTK2.ScrolledWindow((["hadjustment":GTK2.Adjustment(),"vadjustment":subw->scr=GTK2.Adjustment(),"background":"black"]))
				->add(subw->display=GTK2.DrawingArea()->add_events(GTK2.GDK_POINTER_MOTION_MASK|GTK2.GDK_BUTTON_PRESS_MASK|GTK2.GDK_BUTTON_RELEASE_MASK))
				->set_policy(GTK2.POLICY_AUTOMATIC,GTK2.POLICY_ALWAYS)
			)
			->pack_end(subw->tabstatus=GTK2.Vbox(0,10),0,0,0)
		)
		->pack_end(subw->ef=GTK2.Entry(),0,0,0)
	->show_all(),GTK2.Label(subw->tabtext=txt))->set_current_page(sizeof(win->tabs)-1);
	//Note: It'd be nice if Ctrl-Z could do an Undo in in subw->ef. It's
	//probably impractical though - GTK doesn't offer that directly, I'd
	//have to do the work myself.
	setfonts(subw);
	collect_signals("subw_",subw,subw);
	subw->ef->get_settings()->set_property("gtk-error-bell",persist["window/errorbell"]);
	values(G->G->tabstatuses)->install(subw);
	subw_ef_changed(subw->ef,subw);
	call_out(redraw,0,subw);
	return subw;
}

/**
 * Return the subw mapping for the currently-active tab.
 */
mapping(string:mixed) current_subw() {return win->tabs[win->notebook->get_current_page()];}

//Check whether a subw still exists
int validate_subw(mapping subw) {return has_value(win->tabs, subw);}

/**
 * Get a suitable Pango font for a particular category. Will cache based on font name.
 *
 * @param	category		the category of font for which to collect the description
 * @return	PangoFontDescription	Font object suitable for GTK2
 */
GTK2.PangoFontDescription getfont(string category)
{
	string fontname=fonts[category]->name;
	return fontdesc[fontname] || (fontdesc[fontname]=GTK2.PangoFontDescription(fontname));
}

//Update the tabstops array based on a new pixel width
void settabs(int w)
{
	//This currently produces a spew of warnings. I don't know of a way to suppress them, and
	//everything does seem to be functioning correctly. So we suppress stderr for the moment.
	object silence_errors=redirect(Stdio.stderr);
	tabstops=(({GTK2.PangoTabArray})*8)(0,1); //Construct eight TabArrays (technically the zeroth one isn't needed)
	for (int i=1;i<20;++i) //Number of tab stops to place
		foreach (tabstops;int pos;object ta) ta->set_tab(i,GTK2.PANGO_TAB_LEFT,8*w*i-pos*w);
}

//Set/update fonts and font metrics
void setfonts(mapping(string:mixed) subw)
{
	subw->display->modify_font(getfont("display"));
	subw->ef->modify_font(getfont("input"));
	mapping dimensions=subw->display->create_pango_layout("n")->index_to_pos(0);
	//Note that lineheight is the expected height of every line, but charwidth
	//is simply an average - it's used for tab widths and such, that's all.
	subw->lineheight=dimensions->height/1024; subw->charwidth=dimensions->width/1024;
	settabs(subw->charwidth);
}

//Reestablish event handlers for all subwindows as well as for the main window
void dosignals()
{
	::dosignals();
	foreach (win->tabs,mapping subw) collect_signals("subw_",subw,subw);
}

//Snapshot the selection bounds so the switch_page handler can reset them
int subw_ef_focus_in_event(object self,object ev,mapping subw) {subw->cursor_pos_last_focus_in=self->get_selection_bounds();}

//Snap the scroll bar to the bottom every time its range changes (ie when a line is added)
void subw_scr_changed(object self,mapping subw)
{
	if (paused) return;
	float upper=self->get_property("upper");
	self->set_value(upper-self->get_property("page size"));
}

void subw_b4_ef_paste_clipboard(object self,mapping subw)
{
	string txt=self->get_clipboard(GTK2.Gdk_Atom("CLIPBOARD"))->wait_for_text();
	if (!txt || !has_value(txt,'\n')) return; //No text? Nothing will happen. One line of text? Let it go with the default.
	self->signal_stop("paste_clipboard"); //Prevent the full paste, we'll do it ourselves.
	array(string) lines=txt/"\n";
	sscanf(self->get_text(),"%"+self->get_position()+"s%s",string before,string after); //A bit hackish... get the text before and after the cursor :)
	enterpressed(subw,before+lines[0]);
	foreach (lines[1..<1],string l) enterpressed(subw,l);
	self->set_text(lines[-1]+after); self->set_position(sizeof(lines[-1]));
}

GTK2.Widget makestatus()
{
	statustxt->paused=GTK2.Label(pausedmsg);
	statustxt->paused->set_size_request(statustxt->paused->size_request()->width,-1)->set_text(""); //Have it consume space for the PAUSED message even without having it
	return GTK2.Hbox(0,10)->add(statustxt->lbl=GTK2.Label((["xalign":1.0])))->add(statustxt->paused);
}

constant options_highlightwords="_Highlight words";
class highlightwords(mixed|void selectme)
{
	inherit configdlg;
	constant persist_key="window/highlight";
	constant strings=({"descr"});
	constant ints=({"bgcol"});
	void create() {::create();}
	GTK2.Widget make_content()
	{
		return GTK2.Vbox(0,10)
			->pack_start(two_column(({
				"Word",win->kwd=GTK2.Entry(),
				"Bg color",win->bgcol=SelectBox(enumcolors),
				"Last change",win->lastchange=GTK2.Label(),
			})),0,0,0)
			->add(GTK2.Frame("Description")->add(
				win->descr=MultiLineEntryField()->set_size_request(250,70)->set_wrap_mode(GTK2.WRAP_WORD)
			))
			->pack_start(GTK2.Label((["label":"Any words listed here will be highlighted any time they occur"
				" in the display. You can add notes to any word/phrase in this way.","wrap":1])),0,0,0)
		;
	}
	void makewindow()
	{
		::makewindow();
		if (stringp(selectme)) select_keyword(selectme) || win->kwd->set_text(selectme);
	}
	void save_content(mapping(string:mixed) info)
	{
		info->lastchange=time(); load_content(info);
		redraw(current_subw());
	}
	void load_content(mapping(string:mixed) info)
	{
		win->lastchange->set_text(info->lastchange?ctime(info->lastchange)[..<1]:"");
		win->bgcol->set_active(info->bgcol || 13);
	}
	void delete_content(string kwd,mapping(string:mixed) info) {redraw(current_subw());}
}

//Convert a y coordinate into a line number - like point_to_char() but gives only the line.
int point_to_line(mapping subw,int y)
{
	return limit(0,(y-(int)subw->scr->get_property("page size"))/subw->lineheight,sizeof(subw->lines)+1);
}

/* To consider:

Some people may want to show the prompt actually to the left of the input box, instead of a line above it.
This will have a number of consequences, including:
* Possible visual space utilization problems, if the prompt gets too long
* Horizontal scrolling - should it hide the prompt?? Would be hard.
* RTL text??? Nigh impossible to do perfectly.
* Mark-and-copy concerns - can you sweep across from text to prompt?
* Flicker as prompts come and go, and the input box thus shifts left and right
* Other concerns?

Current conclusion (20150517): Not worth doing - too many nasty edge cases. Might be something to play with but that's all.
More importantly, this is something that would require two drastically different code branches, and neither is clearly
the winner. Maintaining both branches simultaneously would be a horrific mess. Switching to prompt-beside-input would allow
a few cleanups (everything that says (line>=sizeof(subw->lines))?subw->prompt:subw->lines[line] could now ignore the prompt
and just use subw->lines[line]), but it'd introduce a comparable level of mess elsewhere, and there is no way that I want
both messes at once.
*/

//Convert (x,y) into (line,col) - yes, that switches their order.
//Note that line and col may exceed the array index limits by 1 - equalling sizeof(subw->lines) or the size of the string at that line.
//A return value equal to the array/string size represents the prompt or the (implicit) newline at the end of the string.
array(int) point_to_char(mapping subw,int x,int y)
{
	int line=point_to_line(subw,y);
	string txt=line_text((line>=sizeof(subw->lines))?subw->prompt:subw->lines[line]);
	object layout=subw->display->create_pango_layout(txt);
	mapping pos=layout->xy_to_index((x-3)*1024,0);
	destruct(layout);
	if (!pos) return ({line,sizeof(txt)});
	//In pos->index, we have a *byte* position. We need to convert this into
	//a *character* position, as txt is Unicode. Pango counts bytes using
	//UTF-8 under the covers; so let's do a rather ham-fisted byte->char
	//calculation by converting to bytes, then truncating, then back to text.
	//I've never seen the position point to the middle of a character anywhere;
	//that would majorly mess me up, if it ever happened (an exception thrown
	//here could trigger any time you highlight past something).
	int bytepos=pos->index;
	int charpos=sizeof(utf8_to_string(string_to_utf8(txt[..bytepos-1])[..bytepos-1]));
	//Yeah, ouch.
	return ({line,charpos});
}

string word_at_pos(mapping subw,int line,int col)
{
	//Go through the line clicked on. Find one single word in one single color, and that's
	//what was clicked on. TODO: Optionally permit the user to click on something with a
	//modifier key (eg Ctrl-Click) to execute something as a command - would play well with
	//help files highlighted in color, for instance. (I've already used Ctrl-DblClk for the
	//keyword highlight shorthand, so this can't use Ctrl-Click, but I don't know what else
	//would make sense. Alt-Click? Something with a double-click in it?)
	foreach ((line>=sizeof(subw->lines))?subw->prompt:subw->lines[line],mixed x) if (stringp(x))
	{
		col-=sizeof(x); if (col>0) continue;
		col+=sizeof(x); //Go back to the beginning of this color block - we've found something.
		foreach (x/" ",string word)
		{
			col-=sizeof(word)+1; if (col>=0) continue;
			//We now have the exact word, delimited by color boundary and blank space.
			return word;
		}
	}
}

/**
 * Clear any previous highlight, and highlight from (line1,col1) to (line2,col2)
 * Will trigger a repaint of all affected areas.
 * If line1==-1, will remove all highlight.
 */
void highlight(mapping subw,int line1,int col1,int line2,int col2)
{
	if (has_index(subw,"selstartline")) //There's a previous highlight. Clear it (by queuing draw for those lines).
	{
		//Note that the unhighlight sometimes isn't working when selstartline>selendline. Need to track down.
		int y1= min(subw->selstartline,subw->selendline)   *subw->lineheight;
		int y2=(max(subw->selstartline,subw->selendline)+1)*subw->lineheight;
		subw->display->queue_draw_area(0,subw->scr->get_property("page size")+y1,1<<30,y2-y1);
	}
	if (line1==-1) {m_delete(subw,"selstartline"); subw->display->queue_draw(); return;} //Unhighlight (with a full redraw for safety)
	subw->selstartline=line1; subw->selstartcol=col1; subw->selendline=line2; subw->selendcol=col2;
	int y1= min(line1,line2)   *subw->lineheight;
	int y2=(max(line1,line2)+1)*subw->lineheight;
	subw->display->queue_draw_area(0,subw->scr->get_property("page size")+y1,1<<30,y2-y1);
}

void subw_display_button_press_event(object self,object ev,mapping subw)
{
	[int line,int col]=point_to_char(subw,(int)ev->x,(int)ev->y);
	if (ev->type=="2button_press")
	{
		//Double-click. Configure highlighting - if it's already a highlighted word, then
		//any double-click will do, otherwise require ctrl-dbl-click. Note that this doesn't
		//look to see if the mouse is over a highlight; it picks up a word, nothing more. If
		//a phrase is highlighted, or only part of the word (imagine putting a highlight on
		//a person's name, and then seeing that name with punctuation), this won't be hit.
		string word=word_at_pos(subw,line,col);
		if (highlightkeywords[word] || ev->state&GTK2.GDK_CONTROL_MASK) highlightwords(word);
		return;
	}
	highlight(subw,line,col,line,col);
	subw->mouse_down=1;
	subw->boxsel = ev->state&GTK2.GDK_SHIFT_MASK; //Note that box-vs-stream is currently set based on shift key as mouse went down. This may change.
}

void subw_display_button_release_event(object self,object ev,mapping subw)
{
	int mouse_down=m_delete(subw,"mouse_down"); //Destructive query
	if (!mouse_down) return; //Mouse wasn't registered as down, do nothing.
	subw->autoscroll=0; //When the mouse comes up, we stop scrolling.
	[int line,int col]=point_to_char(subw,(int)ev->x,(int)ev->y);
	string content;
	if (mouse_down==1)
	{
		//Mouse didn't move between going down and going up. Consider it a click.
		highlight(subw,-1,0,0,0);
		string word=word_at_pos(subw,line,col); if (!word) return;
		//TODO: Detect URLs if they follow punctuation, eg "Check this out:http://....."
		//TODO: Detect URLs that got wrapped across multiple lines, maybe only if shift held or something
		if (has_prefix(word,"http://") || has_prefix(word,"https://") || has_prefix(word,"www."))
			invoke_browser(word);
		//Couldn't find anything to click on.
		return;
	}
	if (subw->selstartline==line)
	{
		//Single-line selection: special-cased for simplicity.
		if (subw->selstartcol>col) [col,subw->selstartcol]=({subw->selstartcol,col});
		content=line_text((line>=sizeof(subw->lines))?subw->prompt:subw->lines[line])+"\n";
		content=content[subw->selstartcol..col-1];
	}
	else
	{
		if (subw->selstartline>line) [line,col,subw->selstartline,subw->selstartcol]=({subw->selstartline,subw->selstartcol,line,col});
		if (subw->boxsel && subw->selstartcol>col) [col,subw->selstartcol]=({subw->selstartcol,col});
		content="";
		for (int l=subw->selstartline;l<=line;++l)
		{
			string curline=line_text((l>=sizeof(subw->lines))?subw->prompt:subw->lines[l]);
			if (subw->boxsel) content+=curline[subw->selstartcol..col-1]+"\n";
			else if (l==line) content+=curline[..col-1];
			else if (l==subw->selstartline) content+=curline[subw->selstartcol..]+"\n";
			else content+=curline+"\n";
		}
	}
	highlight(subw,-1,0,0,0);
	subw->display->get_clipboard(GTK2.Gdk_Atom("CLIPBOARD"))->set_text(content);
}

string hovertext(mapping subw,int line)
{
	string txt=sprintf("Line %d of %d",line,sizeof(subw->lines));
	catch
	{
		mapping meta = (line>=sizeof(subw->lines) ? subw->prompt : subw->lines[line])[0];
		if (!mappingp(meta)) break;
		//Note: If the line has no timestamp (such as the prompt after a local command),
		//this will show the epoch in either UTC or local time. This looks a bit weird,
		//but is actually less weird than omitting the timestamp altogether and having
		//the box suddenly narrow. Yes, there'll be some odd questions about why there's
		//a timestamp of 1970 (or 1969 if you're behind UTC and showing localtime), but
		//on the whole, that's going to bug people less than the flickering of width is.
		//20140816: This is less of an issue now that the status bar slot's width isn't
		//going to change, but it'd still look ugly to have the ts vanish suddenly.
		mapping ts=(persist["window/timestamp_local"]?localtime:gmtime)(meta->timestamp);
		txt+="  "+strftime(persist["window/timestamp"]||default_ts_fmt,ts);
		//Add further meta-information display here
	}; //Ignore errors. The text should be progressively appended to, so any failure will simply result in truncated hover text.
	return txt;
}

void subw_display_motion_notify_event(object self,object ev,mapping subw)
{
	if (!subw->mouse_down)
	{
		setstatus(hovertext(subw,point_to_line(subw,(int)ev->y)));
		return;
	}
	[int line,int col]=point_to_char(subw,(int)ev->x,(int)ev->y);
	setstatus(hovertext(subw,line));
	if (line!=subw->selendline || col!=subw->selendcol)
	{
		subw->mouse_down=2; //Mouse has moved.
		highlight(subw,subw->selstartline,subw->selstartcol,line,col);
	}
	float low=subw->scr->get_value(),high=low+subw->scr->get_property("page size");
	if (ev->y<low) subw->autoscroll=low-ev->y;
	else if (ev->y>high) subw->autoscroll=high-ev->y;
	else subw->autoscroll=0;
	if (subw->autoscroll && !subw->autoscroll_callout) subw->autoscroll_callout=call_out(autoscroll,0.1,subw);
}

void autoscroll(mapping subw)
{
	if (!subw->autoscroll || !subw->mouse_down) {m_delete(subw,"autoscroll_callout"); return;}
	subw->autoscroll_callout=call_out(autoscroll,0.1,subw);
	subw->scr->set_value(limit(0.0,subw->scr->get_value()-subw->autoscroll,subw->scr->get_property("upper")-subw->scr->get_property("page size")));
	//Optional: Trigger a mousemove with the mouse at its current location, to update highlight. Not a big deal if not (just a display oddity).
}

/**
 * Add a line of output (anything other than a prompt)
 * If msg is an array, it is assumed to be alternating colors and text.
 * Otherwise, additional arguments will be processed with sprintf().
 */
void say(mapping|void subw,string|array msg,mixed ... args)
{
	if (!subw) subw=current_subw();
	if (stringp(msg))
	{
		if (sizeof(args)) msg=sprintf(msg,@args);
		if (msg[-1]=='\n') msg=msg[..<1];
		foreach (msg/"\n",string line) say(subw,({7,line}));
		return;
	}
	if (!mappingp(msg[0])) msg=({([])})+msg;
	msg[0]->timestamp=time(1);
	//Clean up any empty strings in msg, for efficiency
	for (int i=2;i<sizeof(msg);i+=2) if (msg[i]=="") {msg=msg[..i-2]+msg[i+1..]; i-=2;}
	if (subw->logfile) subw->logfile->write(string_to_utf8(line_text(msg)+"\n"));
	array lines=({ });
	//Wrap msg into lines, making at least one entry. Note that, in current implementation,
	//it'll wrap at any color change as if it were a space. This is unideal, but it
	//simplifies the code a bit.
	int wrap=persist["window/wrap"]; string wrapindent=persist["window/wrapindent"]||"";
	int pos=0;
	if (wrap) for (int i=2;i<sizeof(msg);i+=2)
	{
		int end=pos+sizeof(msg[i]);
		if (end<=wrap) {pos=end; continue;}
		array cur=msg[..i];
		string part=msg[i];
		end=wrap-pos;
		if (sizeof(part)>end)
		{
			int wrappos=end;
			if (!persist["window/wraptochar"]) while (wrappos && part[wrappos]!=' ') --wrappos;
			//If there are no spaces, break at the color change (if there's text before it), or just break where there's no space.
			//Note that this will refuse to break at or within the wrapindent, on subsequent lines (to prevent an infinite loop).
			if ((!wrappos || (sizeof(lines) && wrappos<=sizeof(wrapindent))) && !pos) wrappos=wrap;
			cur[-1]=part[..wrappos-1];
			msg=({msg[0]+([]),msg[i-1],wrapindent+String.trim_all_whites(part[wrappos..])})+msg[i+1..];
		}
		lines+=({cur});
		i=pos=0;
	}
	subw->lines+=lines+({msg});
	subw->activity=1;
	if (!mainwindow->is_active()) switch (persist["notif/activity"])
	{
		case 1: if (subw!=current_subw()) break; //Play with fall-through. If the config option is 2, present the window regardless of current_page; if it's one, present only if current page; otherwise, don't present.
		case 2: if (paused) break; //Present the window only if we're not paused.
			//Okay, so let's present ourselves.
			if (persist["notif/present"]) mainwindow->present();
			else mainwindow->set_urgency_hint(1);
	}
	redraw(subw);
}

void connect(string world,mapping|void subw)
{
	if (!subw) subw=current_subw();
	if (!world)
	{
		//Disconnect
		if (!subw->connection || !subw->connection->sock) return; //Silent if nothing to dc
		subw->connection->sock->close(); G->G->connection->sockclosed(subw->connection);
		return;
	}
	mapping info=persist["worlds"][world];
	if (!info)
	{
		if (sscanf(world,"%s%*[ :]%d",string host,int port) && port) info=(["host":host,"port":port,"name":sprintf("%s : %d",host,port)]);
		else {say(subw,"%% Connect to what?"); return;}
	}
	values(G->G->tabstatuses)->connected(subw,world);
	subw->world=world;
	if (subw->connection && subw->connection->sock) {say(subw,"%% Already connected."); return;}
	subw->connection=G->G->connection->connect(subw,info);
	subw->tabtext=info->tabtext || info->name || "(unnamed)";
}

void redraw(mapping subw)
{
	int height=(int)subw->scr->get_property("page size")+subw->lineheight*(sizeof(subw->lines)+1);
	if (height!=subw->totheight) subw->display->set_size_request(-1,subw->totheight=height);
	if (subw==current_subw()) subw->activity=0;
	//Check the current tab text before overwriting, to minimize flicker
	string tabtext="* "*subw->activity+subw->tabtext;
	if (win->notebook->get_tab_label_text(subw->page)!=tabtext) win->notebook->set_tab_label_text(subw->page,tabtext);
	subw->maindisplay->queue_draw();
}

//Called externally to provide an opaque object representing a color state.
//Whatever it returns is to be acceptable in say(); it's just a cookie.
//Supporting 256 color mode would require changes here, plus changes to the
//parsing code in connection.pike, but probably nothing else. Could be worth
//doing, if someone wants to support it. (It might cause some confusion if
//anyone's changed the color definitions, though. A 256-color server would
//expect that 16-color codes will have certain meanings. Or possibly not; if
//the server sends 16-color codes, use the changed defs, otherwise use the
//unchanged 256-color values.)
int mkcolor(int fg,int bg)
{
	return fg | (bg<<16);
}

//Paint one piece of text at (x,y), updates state with the x for the next text.
void painttext(array state,string txt,GTK2.GdkColor fg,GTK2.GdkColor bg)
{
	if (txt=="") return;
	//TODO maybe: Highlight any current search term as per the keywords
	if (!monochrome) foreach (highlightkeywords;string word;mapping info) if (word!="" && has_value(txt,word))
	{
		if (txt==word) {bg=colors[info->bgcol||13]; break;} //Special case: If the highlight is the whole string, change background color and fall through (otherwise we have infinite recursion).
		sscanf(txt,"%s"+word+"%s",string before,string after);
		painttext(state,before,fg,bg); //Normal text before the keyword
		painttext(state,word,fg,colors[info->bgcol||13]); //Different background color for the keyword
		painttext(state,after,fg,bg); //And normal text afterward.
		return;
	}
	[GTK2.DrawingArea display,GTK2.GdkGC gc,int x,int y,int tabpos]=state;
	object layout=display->create_pango_layout(txt);
	if (has_value(txt,'\t'))
	{
		if (tabpos) layout->set_tabs(tabstops[tabpos]); //else the defaults will work fine
		state[4]=sizeof((txt/"\t")[-1])%8;
	}
	else state[4]=(tabpos+sizeof(txt))%8;
	mapping sz=layout->index_to_pos(sizeof(string_to_utf8(txt))); //Note that Pango's "index" is a byte index.
	//TODO: "Know" what the background color is, rather than re-checking based on the monochrome flag
	if (bg!=colors[monochrome && 15]) //Since draw_text doesn't have any concept of "background pixels", we block out with a rectangle first.
	{
		gc->set_foreground(bg); //(sic)
		display->draw_rectangle(gc,1,x,y,(sz->x+sz->width)/1024,sz->height/1024);
	}
	gc->set_foreground(fg);
	display->draw_text(gc,x,y,layout);
	destruct(layout);
	state[2]=x+(sz->x+sz->width)/1024;
}

//Paint one line of text at the given 'y'. Will highlight from hlstart to hlend with inverted fg/bg colors.
void paintline(GTK2.DrawingArea display,GTK2.GdkGC gc,array(mapping|int|string) line,int y,int hlstart,int hlend)
{
	array state=({display,gc,3,y,0}); //State passed on to painttext() and modifiable by it. Could alternatively be done as a closure.
	for (int i=mappingp(line[0]);i<sizeof(line);i+=2) if (sizeof(line[i+1]))
	{
		GTK2.GdkColor fg,bg;
		if (monochrome) {fg=colors[0]; bg=colors[15];} //Override black on white for pure readability
		else {fg=colors[line[i]&15]; bg=colors[(line[i]>>16)&15];} //Normal
		string txt=replace(line[i+1],"\n","\\n");
		if (hlend<0) hlstart=sizeof(txt); //No highlight left to do.
		if (hlstart>0) painttext(state,txt[..hlstart-1],fg,bg); //Draw the leading unhighlighted part (which might be the whole string).
		if (hlstart<sizeof(txt))
		{
			painttext(state,txt[hlstart..min(hlend,sizeof(txt))],bg,fg); //Draw the highlighted part (which might be the whole string).
			if (hlend<sizeof(txt)) painttext(state,txt[hlend+1..],fg,bg); //Draw the trailing unhighlighted part.
		}
		hlstart-=sizeof(txt); hlend-=sizeof(txt);
	}
	if (hlend>=0 && hlend<1<<29) //In block selection mode, draw highlight past the end of the string, if necessary
	{
		if (hlstart>0) {painttext(state," "*hlstart,colors[7],colors[0]); hlend-=hlstart;}
		if (hlend>=0) painttext(state," "*(hlend+1),colors[0],colors[7]);
	}
}

//float painttime=0.0; int paintcount=0;
int subw_display_expose_event(object self,object ev,mapping subw)
{
	int start=ev->y-subw->lineheight,end=ev->y+ev->height+subw->lineheight; //We'll paint complete lines, but only those lines that need painting.
	GTK2.DrawingArea display=subw->display; //Cache, we'll use it a lot
	display->set_background(colors[monochrome && 15]); //In monochrome mode, background is all white.
	/*
	There's some kind of slowdown that can be seen sometimes when Gypsum is running for months on end.
	Possibly to do with updating window, or repeated repaints, or something.
	The delay seems to all happen at the GTK2.GdkGC constructor call below. Normally it takes
	microseconds at worst, but when the slowdown happens, it takes a number of milliseconds (17ms seen)
	and adds up to visible latency.
	- Repeatedly updating window.pike doesn't seem to trigger it.
	- Repeatedly opening and closing zoneinfo doesn't seem to either. Nor charsheet, though there MIGHT be
	a bug in the latter involving a difference between clicking the cross and calling destroy().
	- It doesn't seem to be connected to the number of lines in scrollback, except in that they tend to
	accumulate over time, as does the slowdown. Once there's slowness, it applies to all tabs.

	Some debugging code has been retained here, commented out. Note that all the rest of the code - even
	iterating over large slabs of subw->lines in high level code - takes virtually no time, compared to
	the one constructor call. Note also that stress-testing MAY not be entirely valid, as there seems to
	be some sort of short-term cache applying here; uncommenting the redraw(subw) call at the end doesn't
	trigger the slow-down. TODO: Find out whether uncommenting this _after_ the slowdown has set in makes
	for an infinitely-slow system.

	TODO: Use microkernel.pike to stress-test some of this, eg with the zoneinfo and/or charsheet plugins.
	*/
	//System.Timer tm=System.Timer();
	GTK2.GdkGC gc=GTK2.GdkGC(display);
	//painttime+=tm->peek(); ++paintcount;
	int y=(int)subw->scr->get_property("page size");
	int ssl=subw->selstartline,ssc=subw->selstartcol,sel=subw->selendline,sec=subw->selendcol;
	if (undefinedp(ssl)) ssl=sel=-1;
	else if (ssl>sel || (ssl==sel && ssc>sec)) [ssl,ssc,sel,sec]=({sel,sec,ssl,ssc}); //Get the numbers forward rather than backward
	if (subw->boxsel && ssc>sec) [ssc,sec]=({sec,ssc}); //With box selection, row and column are independent.
	if (ssl==sel && ssc==sec) ssl=sel=-1;
	int endl=min((end-y)/subw->lineheight,sizeof(subw->lines));
	for (int l=max(0,(start-y)/subw->lineheight);l<=endl;++l)
	{
		array(mapping|int|string) line=(l>=sizeof(subw->lines)?subw->prompt:subw->lines[l]);
		int hlstart=-1,hlend=-1;
		if (l>=ssl && l<=sel)
		{
			if (subw->boxsel) {hlstart=ssc; hlend=sec-1;}
			else
			{
				if (l==ssl) hlstart=ssc;
				if (l==sel) hlend=sec-1; else hlend=1<<30;
			}
		}
		paintline(display,gc,line,y+l*subw->lineheight,hlstart,hlend);
	}
	//werror("Paint: %f/%d = %f avg\n",painttime,paintcount,painttime/paintcount);
	//redraw(subw);
	//call_out(G->G->hooks->zoneinfo->menu_clicked()->closewindow,0.01);
	//call_out(G->G->hooks->charsheet->charsheet(subw->connection,"nobody",([]))->sig_mainwindow_destroy,0.01);
}

void settext(mapping subw,string text)
{
	subw->ef->set_text(text);
	if (!persist["window/cursoratstart"]) subw->ef->set_position(sizeof(text));
}

int subw_b4_ef_key_press_event(object self,array|object ev,mapping subw)
{
	if (arrayp(ev)) ev=ev[0];
	switch (ev->keyval)
	{
		case 0xFF0D: case 0xFF8D: enterpressed(subw); return 1;
		case 0xFF52: //Up arrow
		{
			if (subw->histpos==-1)
			{
				subw->histpos=sizeof(subw->cmdhist);
				subw->last_ef=subw->ef->get_text();
			}
			if (!subw->histpos) return 1;
			int pos = (ev->state&GTK2.GDK_CONTROL_MASK) && subw->ef->get_position();
			string txt = subw->ef->get_text();
			string pfx = txt[..pos-1];
			int hp=subw->histpos;
			while (hp && (!has_prefix(subw->cmdhist[--hp],pfx) || subw->cmdhist[hp]==txt));
			if (has_prefix(subw->cmdhist[hp],pfx)) settext(subw,subw->cmdhist[subw->histpos=hp]);
			if (ev->state&GTK2.GDK_CONTROL_MASK) subw->ef->set_position(pos);
			return 1;
		}
		case 0xFF54: //Down arrow
		{
			if (subw->histpos==-1) switch (persist["window/downarr"])
			{
				case 2: //Save into history
					string cmd=subw->ef->get_text();
					if (cmd!="" && (!sizeof(subw->cmdhist) || cmd!=subw->cmdhist[-1])) subw->cmdhist+=({cmd});
					subw->histpos=-1;
				case 1: subw->ef->set_text(""); //Blank the EF
				default: return 1;
			}
			int pos = (ev->state&GTK2.GDK_CONTROL_MASK) && subw->ef->get_position();
			string txt = subw->ef->get_text();
			string pfx = txt[..pos-1];
			int hp=subw->histpos;
			while (++hp<sizeof(subw->cmdhist) && (!has_prefix(subw->cmdhist[hp],pfx) || subw->cmdhist[hp]==txt));
			if (hp<sizeof(subw->cmdhist)) settext(subw,subw->cmdhist[subw->histpos=hp]);
			//Note that the handling of this feature of the up arrow is actually here in the *down* arrow's code.
			else if (pfx=="" && persist["window/uparr"]) {settext(subw,subw->last_ef); subw->histpos=-1;}
			else {subw->ef->set_text(pfx); subw->histpos=-1;}
			if (ev->state&GTK2.GDK_CONTROL_MASK) subw->ef->set_position(pos);
			return 1;
		}
		case 0xFF1B: //Esc
			if (has_index(subw,"selstartline")) {highlight(subw,-1,0,0,0); subw->mouse_down=0;}
			else subw->ef->set_text(""); //Clear EF if there's nothing to unhighlight
			return 1;
		case 0xFF09: case 0xFE20: //Tab and shift-tab
		{
			if (ev->state&GTK2.GDK_CONTROL_MASK)
			{
				//Not using win->notebook->{next|prev}_page() as they don't cycle.
				int page=win->notebook->get_current_page();
				if (ev->state&GTK2.GDK_SHIFT_MASK) {if (--page<0) page=win->notebook->get_n_pages()-1;}
				else {if (++page>=win->notebook->get_n_pages()) page=0;}
				win->notebook->set_current_page(page);
				return 1;
			}
			subw->ef->set_position(subw->ef->insert_text("\t",1,subw->ef->get_position()));
			return 1;
		}
		case 0xFF55: //PgUp
		{
			if (ev->state&GTK2.GDK_CONTROL_MASK)
			{
				//Scroll up to last activity. Note that this is stored by scrollbar
				//position, not line index, so a change of font/size might disrupt it.
				//The value will be clamped to the range, so the worst effect is that
				//it'll take an extra hit of PgUp to get to normality. Not a big deal.
				if (subw->last_activity) subw->scr->set_value(subw->last_activity);
				paused=1; statustxt->paused->set_text(pausedmsg);
				return 1;
			}
			object scr=subw->scr; scr->set_value(scr->get_value()-scr->get_property("page size"));
			return 1;
		}
		case 0xFF56: //PgDn
		{
			object scr=subw->scr;
			float pg=scr->get_property("page size");
			if (ev->state&GTK2.GDK_CONTROL_MASK)
			{
				//Snap down to the bottom and unpause.
				scr->set_value(scr->get_property("upper")-pg);
				paused=0;
				statustxt->paused->set_text("");
				return 1;
			}
			scr->set_value(min(scr->get_value()+pg,scr->get_property("upper")-pg));
			return 1;
		}
		#if constant(DEBUG)
		case 0xFFE1: case 0xFFE2: //Shift
		case 0xFFE3: case 0xFFE4: //Ctrl
		case 0xFFE7: case 0xFFE8: //Windows keys
		case 0xFFE9: case 0xFFEA: //Alt
			break;
		default: say(subw,"%%%% keypress: %X",ev->keyval); break;
		#endif
	}
	if (mapping numpad=numpadnav[sprintf("%x",ev->keyval)])
	{
		if (persist["window/numpadempty"] && subw->ef->get_text()!="") return 0;
		string cmd=numpad->cmd;
		//Should *all* slash commands be permitted? That might be clean.
		if (cmd=="/lastnav") {if (function f=G->G->commands->lastnav) f("",subw); return 1;}
		if (!numpadspecial[cmd] && !has_prefix(cmd,"go ")) cmd="go "+cmd;
		if (!subw->lastnav) subw->lastnav=({ });
		if (has_prefix(cmd,"go ")) subw->lastnav+=({cmd[3..]});
		if (persist["window/numpadecho"]) enterpressed(subw,cmd);
		else send(subw->connection,cmd+"\r\n");
		return 1;
	}
}

void enterpressed(mapping subw,string|void cmd)
{
	if (!cmd) {cmd=subw->ef->get_text(); subw->ef->set_text("");}
	subw->histpos=-1;
	subw->prompt[0]->timestamp=time(1);
	m_delete(subw->prompt[0],"text"); //Wipe the cached text version of the line, which is now going to be wrong
	if (!persist["window/hideinput"])
	{
		if (!subw->passwordmode)
		{
			if (cmd!="" && (!sizeof(subw->cmdhist) || cmd!=subw->cmdhist[-1])) subw->cmdhist+=({cmd});
			int inputcol=persist["window/inputcol"]; if (undefinedp(inputcol)) inputcol=6;
			say(subw,subw->prompt+({inputcol,cmd}));
		}
		else subw->lines+=({subw->prompt});
	}
	subw->prompt[0]=([]); //Reset the info mapping (which gets timestamp and such) but keep the prompt itself; it's execcommand's job to remove it.
	subw->last_activity=subw->scr->get_property("upper")-subw->scr->get_property("page size");
	if (has_prefix(cmd,"//")) cmd=cmd[1..];
	else if (has_prefix(cmd,"/"))
	{
		redraw(subw);
		sscanf(cmd,"/%[^ ] %s",cmd,string args);
		if (G->G->commands[cmd] && G->G->commands[cmd](args||"",subw)) return;
		say(subw,"%% Unknown command.");
		return 0;
	}
	if (array nav=m_delete(subw,"lastnav")) subw->lastnav_desc=nav*", "; //TODO: If window/numpadecho, does this destroy the value of /lastnav?
	execcommand(subw,cmd,0);
}

//Run all registered hooks, in order; or run all hooks after a given hook.
//If any hook returns nonzero, hook execution will be terminated and nonzero returned.
//(NOTE: A future change may have the aborting hook name returned, so don't depend on
//the exact return value in this situation, beyond that it will be a true value.) If
//any hook throws an exception, that will be printed out to the subw and the next hook
//called upon (as if the hook returned zero). Zero will be returned once all hooks
//have been processed.
int runhooks(string hookname,string|void skiphook,mapping(string:mixed) subw,mixed ... otherargs)
{
	//Sort by name for consistency. May be worth keeping them sorted somewhere, but I'm not seeing performance problems.
	array names=indices(G->G->hooks),hooks=values(G->G->hooks); sort(names,hooks);
	foreach (hooks;int i;object hook) if (!skiphook || skiphook<names[i])
		if (mixed ex=catch {if (hook[hookname](subw,@otherargs)) return 1;})
			say(subw,"Error in hook %s->%s: %s",names[i],hookname,describe_backtrace(ex));
}

/**
 * Execute a command, passing it via hooks
 * If skiphook is nonzero, will skip all hooks up to and including that name.
 * If the subw is in password mode, hooks will not be called at all.
 */
void execcommand(mapping subw,string cmd,string|void skiphook)
{
	if (!subw->passwordmode && runhooks("input",skiphook,subw,cmd)) {redraw(subw); return;}
	subw->prompt=({([])}); redraw(subw);
	send(subw->connection,cmd+"\r\n");
}

/**
 * Engage/disengage password mode
 */
void   password(mapping subw) {subw->passwordmode=1; subw->ef->set_visibility(0);}
void unpassword(mapping subw) {subw->passwordmode=0; subw->ef->set_visibility(1);}

constant file_addtab=({"_New Tab",'t',GTK2.GDK_CONTROL_MASK});
void addtab() {subwindow("New tab");}

/**
 * Actually close a tab - that is, assume the user has confirmed the closing or doesn't need to
 * May be worth providing a plugin hook at this point for notifications - clean up refloops or
 * other now-unnecessary retained data.
 *
 * Note that closetab hooks are still allowed to prevent the closure. It would be possible to
 * turn the close confirmation into a hook that returns 1 (though there'd need to be a nexthook
 * equivalent here).
 */
void real_closetab(int removeme)
{
	if (runhooks("closetab",0,win->tabs[removeme],removeme)) return;
	if (sizeof(win->tabs)<2) addtab();
	win->tabs[removeme]->signals=0; connect(0,win->tabs[removeme]);
	win->tabs=win->tabs[..removeme-1]+win->tabs[removeme+1..];
	win->notebook->remove_page(removeme);
	if (!sizeof(win->tabs)) addtab();
}

/**
 * First-try at closing a tab. May call real_closetab() or raise a prompt.
 */
constant file_closetab=({"Close Tab",'w',GTK2.GDK_CONTROL_MASK});
void closetab()
{
	int removeme=win->notebook->get_current_page();
	if (persist["window/confirmclose"]==-1 || !win->tabs[removeme]->connection || !win->tabs[removeme]->connection->sock) real_closetab(removeme); //TODO post 7.8: Use ?->sock for this
	else confirm(0,"You have an active connection, really close this tab?",mainwindow,real_closetab,removeme);
}

void set_error_bell(int state)
{
	win->tabs->ef->get_settings()->set_property("gtk-error-bell",state);
}

/* This is called "zadvoptions" rather than "advoptions" to force its menu item
to be at the end of the Options menu. It's a little odd, but that's the only
one that needs to be tweaked to let the menu simply be in funcname order. */
constant options_zadvoptions="Ad_vanced options";
class zadvoptions
{
	inherit configdlg;
	mapping(string:mapping(string:mixed)) items=([
		//Keep these in alphabetical order for convenience - they'll be shown in that order anyway
		"Activity alert":(["path":"notif/activity","type":"int","desc":"The Gypsum window can be 'presented' to the user in a platform-specific way. When should this happen?","options":([0:"Never present the window",1:"Present on activity in current tab",2:"Present on any activity"])]),
		"Beep":(["path":"notif/beep","type":"int","desc":"When the server requests a beep, what should be done?\n\n0: Try both the following, in order\n1: Call on an external 'beep' program\n2: Use the GTK2 beep() action\n99: Suppress the beep entirely"]),

		#define COMPAT(x) " Requires restart."+(has_index(all_constants(),"COMPAT_"+upper_case(x))?"\n\nCurrently active.":"\n\nCurrently inactive.")+"\n\nYou do NOT normally need to change this.","type":"int","path":"compat/"+x,"options":([0:"Autodetect"+({" (disable)"," (enable)"})[G->compat[x]],1:"Enable compatibility mode",2:"Disable compatibility mode"])
		"Compat: Boom2":(["desc":"Older versions of Pike have a bug that can result in a segfault under certain circumstances."COMPAT("boom2")]),
		"Compat: Msg Dlg":(["desc":"Older versions of Pike have a bug that can result in a segfault with message boxes."COMPAT("msgdlg")]),
		"Compat: Pause key":(["desc":"On some systems, the Pause key generates the wrong key code. If pressing Pause doesn't pause scrolling, enable this to use Ctrl-P instead."COMPAT("pausekey")]),

		"Confirm on Close":(["path":"window/confirmclose","type":"int","desc":"Normally, Gypsum will prompt before closing, in case you didn't mean to close.","options":([0:"Confirm if there are active connections",1:"Always confirm",-1:"Never confirm, incl when closing a tab"])]),
		"Cursor at start/end":(["path":"window/cursoratstart","type":"int","desc":"When seeking through command history, should the cursor be placed at the start or end of the command?","options":([0:"End of command (default)",1:"Start of command"])]),
		"Down arrow":(["path":"window/downarr","type":"int","desc":"When you press Down when you haven't been searching back through command history, what should be done?","options":([0:"Do nothing, leave the text there",1:"Clear the input field",2:"Save into history and clear input"])]),
		"Error bell":(["path":"window/errorbell","type":"int","desc":"Should pressing Backspace when the input field is empty result in a beep?","options":([0:"No - silently do nothing",1:"Yes - beep"]),"savefunc":set_error_bell]),
		"Hide input":(["path":"window/hideinput","type":"int","desc":"Local echo is active by default, but set this to disable it and hide all your commands.","options":([0:"Disabled (show commands)",1:"Enabled (hide commands)"])]),
		"Input color":(["path":"window/inputcol","type":"int","default":6,"desc":"If input is not hidden, commands will be echoed locally, following the prompt, in some color. The specific color can be configured here.","options":mkmapping(enumerate(16),enumcolors)]),
		"Keep-Alive":(["path":"ka/delay","default":240,"desc":"Number of seconds between keep-alive messages. Set this to a little bit less than your network's timeout. Note that this should not reset the server's view of idleness and does not violate the rules of Threshold RPG.","type":"int"]),
		"Numpad Nav echo":(["path":"window/numpadecho","desc":"Enable this to have numpad navigation commands echoed as if you'd typed them; disabling gives a cleaner display.","type":"int","options":([0:"Disabled",1:"Enabled"])]),
		"Numpad empty only":(["path":"window/numpadempty","desc":"If you have conflicts with numpad nav keys and regular typing, you can prevent numpad nav from happening when there's anything typed.","type":"int","options":([0:"Always active",1:"Only when empty"])]),
		"Present action":(["path":"notif/present","type":"int","desc":"Activity alerts can present the window in one of two ways. Note that the exact behaviour depends somewhat on your window manager.","options":([0:"Mark the window as 'urgent'",1:"Request immediate presentation"])]),
		"Reopen closed tabs":(["path":"reopentabs","type":"int","desc":"Bring back what once was yours... When Gypsum is invoked, you can have it reopen with whatever tabs were previously open. Or you can reopen some fixed set every time.","options":([0:"Do nothing",1:"Remember but don't retrieve",2:"Retrieve but don't remember",3:"Retrieve, and remember"])]),
		"Timestamp":(["path":"window/timestamp","default":default_ts_fmt,"desc":"Display format for line timestamps as shown when the mouse is hovered over them. Uses strftime markers. TODO: Document this better."]),
		"Timestamp localtime":(["path":"window/timestamp_local","desc":"Line timestamps can be displayed in your local time rather than in UTC, if you wish.","type":"int","options":([0:"Normal - use UTC",1:"Use your local time"])]),
		"Up arrow":(["path":"window/uparr","type":"int","desc":"When you press Up to begin searching back through command history, should the current text be saved and recalled when you come back down to it?","options":([0:"No",1:"Yes"])]),
		"Wrap":(["path":"window/wrap","desc":"Wrap text to the specified width (in characters). 0 to disable.","type":"int"]),
		"Wrap indent":(["path":"window/wrapindent","default":"","desc":"Indent/prefix wrapped text with the specified text - a number of spaces works well."]),
		"Wrap to chars":(["path":"window/wraptochar","type":"int","desc":"Normally it makes sense to wrap at word boundaries (spaces) where possible, but you can disable this if you wish.","options":([0:"Default - wrap to words",1:"Wrap to characters"])]),
	]);
	constant allow_new=0;
	constant allow_rename=0;
	constant allow_delete=0;
	mapping(string:mixed) windowprops=(["title":"Advanced Options"]);
	void create() {::create();}

	GTK2.Widget make_content()
	{
		return GTK2.Vbox(0,10)
			->pack_start(win->kwd=GTK2.Label((["yalign":1.0])),0,0,0)
			->pack_start(win->value=GTK2.Entry()->set_no_show_all(1),0,0,0)
			->pack_start(win->select=SelectBox(({}))->set_no_show_all(1),0,0,0)
			->pack_end(win->desc=GTK2.Label((["xalign":0.0,"yalign":0.0]))->set_size_request(300,150)->set_line_wrap(1),1,1,0)
		;
	}

	void save_content(mapping(string:mixed) info)
	{
		mixed value=win->value->get_text();
		if (info->options) value=search(info->options,win->select->get_text());
		if (info->type=="int") value=(int)value; else value=(string)value;
		persist[info->path]=value;
		if (info->savefunc) info->savefunc(value);
	}

	void load_content(mapping(string:mixed) info)
	{
		mixed val=persist[info->path]; if (undefinedp(val) && !undefinedp(info->default)) val=info->default;
		if (mapping opt=info->options)
		{
			win->value->hide(); win->select->show();
			win->select->set_strings(sort(values(opt)));
			win->select->set_text(opt[val]);
		}
		else
		{
			win->select->hide(); win->value->show();
			win->value->set_text((string)val);
		}
		win->desc->set_text(info->desc);
	}
}

constant options_channelsdlg="_Channel Colors";
class channelsdlg
{
	inherit configdlg;
	constant ints=({"r","g","b"});
	constant persist_key="color/channels";
	mapping(string:mixed) windowprops=(["title":"Channel colors"]);
	void create() {::create();} //Pass on no args to the parent

	GTK2.Widget make_content()
	{
		return two_column(({
			"Channel name",win->kwd=GTK2.Entry(),
			"Color (0-255)",GTK2.Hbox(0,10)
				->add(GTK2.Label("Red"))
				->add(win->r=GTK2.Entry()->set_size_request(40,-1))
				->add(GTK2.Label("Green"))
				->add(win->g=GTK2.Entry()->set_size_request(40,-1))
				->add(GTK2.Label("Blue"))
				->add(win->b=GTK2.Entry()->set_size_request(40,-1))
		}));
	}

	void load_content(mapping(string:mixed) info)
	{
		if (undefinedp(info->r)) {info->r=info->g=info->b=255; ({win->r,win->g,win->b})->set_text("255");}
	}
}

constant options_colorsdlg="Co_lors";
class colorsdlg
{
	inherit configdlg;
	constant ints=({"r","g","b"});
	constant allow_new=0,allow_delete=0,allow_rename=0;
	mapping(string:mixed) windowprops=(["title":"Channel colors"]);
	void create()
	{
		items=([]);
		foreach (mainwin->color_defs;int i;[int r,int g,int b]) items[enumcolors[i]]=(["r":r,"g":g,"b":b]);
		::create();
	}

	GTK2.Widget make_content()
	{
		win->kwd=GTK2.Label("13: bold magenta"); //The longest name in the list
		win->kwd->set_size_request(win->kwd->size_request()->width,-1)->set_text("");
		return two_column(({
			"Color",noex(win->kwd),
			"Red",noex(win->r=GTK2.Entry()->set_size_request(40,-1)),
			"Green",noex(win->g=GTK2.Entry()->set_size_request(40,-1)),
			"Blue",noex(win->b=GTK2.Entry()->set_size_request(40,-1)),
			"Colors range from 0 to 255.\nNote that all colors set\nhere are ignored in\nmonochrome mode.",0,
		}));
	}

	void save_content(mapping(string:mixed) info)
	{
		int idx=(int)win->kwd->get_text(); //Will ignore a leading space and everything from the colon on.
		array val=({info->r,info->g,info->b});
		if (equal(val,mainwin->color_defs[idx])) return; //No change.
		mainwin->color_defs[idx]=val;
		colors[idx]=GTK2.GdkColor(@val);
		persist["colors/sixteen"]=mainwin->color_defs; //This may be an unnecessary mutation, but it's simpler to leave this out of persist[] until it's actually changed.
		redraw(current_subw());
	}
}

constant options_fontdlg="_Font";
class fontdlg
{
	inherit configdlg;
	constant persist_key="window/font";
	constant allow_new=0,allow_rename=0,allow_delete=0;
	void create() {::create();}

	GTK2.Widget make_content()
	{
		win->list->set_enable_search(0); //Disable the type-ahead search, which is pretty useless when there are this few items
		return GTK2.Vbox(0,0)
			->add(win->kwd=GTK2.Label((["label":"Section","xalign":0.5])))
			->add(win->fontsel=GTK2.FontSelection())
		;
	}

	void save_content(mapping(string:mixed) info)
	{
		string name=win->fontsel->get_font_name();
		if (info->name==name) return; //No change, no need to dump the cached object
		info->name=name;
		m_delete(fontdesc,name);
		setfonts(mainwin->tabs[*]);
		redraw(mainwin->tabs[*]);
		mainwin->tabs->display->set_background(colors[0]); //For some reason, failing to do this results in the background color flipping to grey when fonts are changed. Weird.
	}

	void load_content(mapping(string:mixed) info)
	{
		if (info->name) win->fontsel->set_font_name(info->name);
	}
}

//TODO: For the standard ones (0xffb[0-9]), show a more friendly description, not just the hex code
//This may require a generalized system of model changes, where the TreeModel doesn't simply report
//the keys of the mapping, but does some processing on them. Experimentation required.
constant options_keyboard="_Keyboard";
class keyboard
{
	inherit configdlg;
	constant strings=({"cmd","keyname"});
	constant persist_key="window/numpadnav";
	constant descr_key="keyname";
	mapping(string:mixed) windowprops=(["title":"Numeric keypad navigation"]);
	void create() {::create();}

	GTK2.Widget make_content()
	{
		return two_column(({
			"Key (hex code)",win->kwd=GTK2.Entry(),
			"Press key here ->",win->key=GTK2.Entry(),
			GTK2.Label("The hex code for any key pressed\nhere will be stored in Key above."),0, //Explicitly construct a label so it isn't right-justified
			"Key name (optional)",win->keyname=GTK2.Entry(),
			"Command",win->cmd=GTK2.Entry(),
		}));
	}

	void makewindow()
	{
		::makewindow();
		//Add a button to the bottom row. Note that this is coming up at the far right;
		//previously, this was a bit ugly, but now that's not a big deal, as 'Save' and
		//'Delete' are elsewhere. So instead of a centered 'Close' button, we get 'Close'
		//on the left and 'Standard' on the right, which looks fine.
		win->buttonbox->add(win->pb_std=GTK2.Button((["label":"Standard","use-underline":1])));
	}

	int sig_b4_key_key_press_event(object self,array|object ev)
	{
		if (arrayp(ev)) ev=ev[0];
		switch (ev->keyval) //Let some keys through untouched
		{
			case 0xFFE1..0xFFEE: //Modifier keys
			case 0xFF09: case 0xFE20: //Tab/shift-tab
				return 0;
		}
		win->kwd->set_text(sprintf("%x",ev->keyval));
		return 1;
	}

	void stdkeys()
	{
		object store=win->list->get_model();
		foreach (({"look","southwest","south","southeast","west","glance","east","northwest","north","northeast"});int i;string cmd)
		{
			if (!numpadnav["ffb"+i])
			{
				numpadnav["ffb"+i]=(["cmd":cmd,"keyname":"Keypad "+i]);
				store->set_value(store->append(),0,"ffb"+i);
			}
			else
			{
				numpadnav["ffb"+i]->cmd=cmd;
				numpadnav["ffb"+i]->keyname="Keypad "+i;
			}
		}
		persist->save();
		sig_sel_changed();
	}

	void sig_pb_std_clicked()
	{
		confirm(0,"Adding/updating standard nav keys will overwrite anything you currently have on those keys. Really do it?",win->mainwindow,stdkeys);
	}
}

constant help_aboutdlg="_About";
class aboutdlg
{
	inherit window;
	void create() {::create();}

	void makewindow()
	{
		string ver=gypsum_version();
		if (ver!=INIT_GYPSUM_VERSION) ver=sprintf("%s (upgraded from %s)",ver,INIT_GYPSUM_VERSION);
		int up=time()-started;
		string uptime=format_time(up%86400);
		if (up>=86400) uptime=(up/86400)+" days, "+uptime;
		win->mainwindow=GTK2.Window((["title":"About Gypsum"]))->add(GTK2.Vbox(0,0)
			->add(GTK2.Label(#"Pike MUD client for Windows/Linux/Mac (and others)

Free software - see README for license terms

By Chris Angelico, rosuav@gmail.com

Version "+ver+#", running on Pike "+pike_version()+#".

This invocation of Gypsum has been running since:
"+strftime("%a %b %d %Y %H:%M:%S",localtime(started))+" - "+uptime))
			->add(GTK2.HbuttonBox()->add(stock_close()))
		);
		::makewindow();
	}
}

constant options_promptsdlg="_Prompts"; //Should this be buried away behind Advanced Options or something?
class promptsdlg
{
	inherit window;
	void create() {::create();}

	string wrap(string txt)
	{
		//return noex(GTK2.Label(replace(txt,({"\n","\t"}),({" ",""})))->set_line_wrap(1)->set_justify(GTK2.JUSTIFY_LEFT));
		return replace(txt,({"\n","\t"}),({" ",""}));
	}

	void makewindow()
	{
		win->mainwindow=GTK2.Window((["title":"Configure prompts"]))->add(GTK2.Vbox(0,20)
			->add(GTK2.Label("Prompts from the server are easy for a human to\nrecognize, but not always for the computer.\nYou can probably ignore all this unless something's broken."))
			->add(GTK2.Frame("TELNET codes")
				->add(GTK2.Label("The ideal is for prompts to be marked with\nIAC GA. This works perfectly and is guaranteed."))
			)
			->add(GTK2.Frame("Magic prompt marker")->add(GTK2Table(({
				({"Next best is a special marker from the server. If this\nends a socket-read, it is treated as a prompt.",0}),
				({"Marker:",win->promptsuffix=GTK2.Entry()->set_text(persist["prompt/suffix"]||"==> ")}),
				({"Blank this to suppress this feature.",0}),
			}))))
			->add(GTK2.Frame("Pseudo-prompts")->add(GTK2Table(({
				({wrap(#"Finally, a piece of text that ends a socket-read may be interpreted as a pseudo-prompt if it ends
				with a typical marker. For most MUDs this would be a colon or a greater-than symbol - :> - but you may
				want to either add to or remove from that list. The marker character may be followed by whitespace
				but nothing else; it may be preceded by anything (the entire line will become the prompt)."),0}),
				({"Pseudo-prompt tail characters:",
					win->promptpseudo = GTK2.Entry()->set_text((stringp(persist["prompt/pseudo"]) && persist["prompt/pseudo"]) || ":>")
				}),
				({"Again, blank this list to suppress this feature.",0}),
				({wrap(#"Alternatively, you could treat every partial line as a pseudo-prompt, regardless of what it ends
				with. This tends to be ugly, but will work; rather than key in every possible ending character above,
				simply tick this box."),0}),
				({win->allpseudo=GTK2.CheckButton("All partial lines are pseudo-prompts"),0}),
				({wrap(#"Since pseudo-prompts are often going to be incorrectly recognized, you may prefer to have
				inputted commands not remove them from the subsequent line. With a guess that can have as many false
				positives as false negatives, it's a judgement call whether to aim for the positive or aim for the
				negative, so take your pick which one you find less ugly. With this option unticked (the default),
				a false positive will result in a broken line if you happen to type a command right at that moment;
				with it ticked, every pseudo-prompt will end up being duplicated into the next line of normal text."),0}),
				({win->retainpseudo=GTK2.CheckButton("Retain pseudo-prompts after commands"),0}),
			}),(["wrap":1,"justify":GTK2.JUSTIFY_LEFT,"xalign":0.0]))))
			->add(GTK2.HbuttonBox()
				->add(win->pb_ok=GTK2.Button((["use-stock":1,"label":GTK2.STOCK_OK])))
				->add(stock_close())
			)
		);
		win->allpseudo->set_active(persist["prompt/pseudo"]==1.0);
		win->retainpseudo->set_active(persist["prompt/retain_pseudo"]);
	}

	void sig_pb_ok_clicked()
	{
		if (win->allpseudo->get_active()) persist["prompt/pseudo"]=1.0;
		else persist["prompt/pseudo"]=win->promptpseudo->get_text();
		persist["prompt/suffix"]=win->promptsuffix->get_text();
		persist["prompt/retain_pseudo"]=win->retainpseudo->get_active();
		closewindow();
	}
}

/* The official key value (GDK_KEY_Pause) is 0xFF13, but Windows produces 0xFFFFFF (GDK_KEY_VoidSymbol)
instead - and also produces it for other keys, eg Caps Lock. This makes it difficult, not to say
dangerous, to provide the keystroke. In those cases, we can use Ctrl-P instead. */
constant options_pause=({"Pa_use scroll",
	#if constant(COMPAT_PAUSEKEY)
	'p',GTK2.GDK_CONTROL_MASK
	#else
	0xFF13,0
	#endif
});
void pause()
{
	paused=!paused;
	statustxt->paused->set_text(pausedmsg*paused);
}

constant options_monochrome_mode="_Monochrome";
void monochrome_mode()
{
	monochrome=!monochrome;
	call_out(redraw,0,current_subw());
	call_out(redraw,0.1,current_subw()); //Forcing another complete redraw seems to help with repaint issues on Windows.
}

//Update the entry field's color based on channel color definitions
void subw_ef_changed(object self,mapping subw)
{
	array(int) col=({255,255,255});
	if (mapping c=channels[(self->get_text()/" ")[0]]) col=({c->r,c->g,c->b});
	if (equal(subw->cur_fg,col)) return;
	subw->cur_fg=col;
	self->modify_base(GTK2.STATE_NORMAL,GTK2.GdkColor(0,0,0));
	self->modify_text(GTK2.STATE_NORMAL,GTK2.GdkColor(@col));
}

//Compile one pike file and let it initialize itself, similar to bootstrap()
//Unlike bootstrap(), sends errors to a local subw.
//This is conceptually part of globals.pike, and it's not actually used here in
//window.pike at all, but since it references say(), it can't go into globals.
//Hmm. This is an argument in favour of a new file plugins.pike, I think... but
//against that is the tab-completion argument, which is stronger than one might
//think. It's not worth breaking that unless it's going to benefit us a lot.
//Maybe call it extras.pike? That doesn't break tab-completion. To justify that
//name, could put everything into there that doesn't specifically need to be
//loaded early; effectively, it'd be a "more globals" file, like Pike's modules
//and post_modules directories. But then, just like with Pike's module dirs,
//there'd be the usual question of "this doesn't _need_ to be early, but it
//doesn't _need_ to be late, so where does it go?". Hrm.
//At the moment, the only functions that would go into "more globals" (extras)
//would be these and discover_plugins() below, so it's hardly worth it. They're
//connected with configure_plugins, so unless I move the whole menu subsystem
//out into another file (which would be possible, albeit not all that useful),
//there's no point moving these functions. They can stay. 20150422: Also now
//runhooks (above). This is growing, but very very slowly.
void compile_error(string fn,int l,string msg) {say(0,"Compilation error on line "+l+": "+msg+"\n");}
void compile_warning(string fn,int l,string msg) {say(0,"Compilation warning on line "+l+": "+msg+"\n");}
object build(string param)
{
	if (!(param=fn(param))) return 0;
	if (!file_stat(param)) {say(0,"File not found: "+param+"\n"); return 0;} //TODO maybe: Unload the file, if possible and safe (see update.pike)
	mapping buildlog=G->G->buildlog; //Controlled with the /buildlog command from plugins/buildlog.pike
	if (buildlog && !buildlog[param]) buildlog[param]=set_weak_flag(([]),Pike.WEAK_VALUES);
	say(0,"%% Compiling "+param+"...");
	//Note that global usage isn't removed. If a plugin formerly used
	//something and now doesn't, it will continue to be updated when
	//that something is updated, until the plugin gets unloaded. This
	//is not considered to be a major issue, and is not worth fixing.
	program compiled; catch {compiled=compile_file(param,this);};
	if (!compiled) {say(0,"%% Compilation failed.\n"); return 0;}
	say(0,"%% Compiled.");
	object obj=compiled(param);
	if (buildlog) buildlog[param][time()]=obj;
	return obj;
}

/*
Policy note on core plugins (this belongs somewhere, but I don't know where): Unlike
RosMud, where plugins were the bit you could reload separately and the core required
a shutdown, there's no difference here between window.pike and plugins/timer.pike.
The choice of whether to make something core or plugin should now be made on the basis
of two factors. Firstly, anything that should be removable MUST be a plugin; core code
is always active. That means that anything that creates a window, statusbar entry, or
other invasive or space-limited GUI content, should usually be a plugin. And secondly, the
convenience of the code. If it makes good sense to have something create a command of
its own name, for instance, it's easier to make it a plugin; but if something needs
to be called on elsewhere, it's better to make it part of core (maybe globals). The
current use of plugins/update.pike by other modules is an unnecessary dependency; it
may still be convenient to have /update handled by that file, but the code that's
called on elsewhere should be broken out into core.
*/
void discover_plugins(string dir)
{
	mapping(string:mapping(string:mixed)) plugins=persist["plugins/status"];
	foreach (get_dir(dir),string fn)
	{
		//Possibly skip hidden files (those starting with a dot), treating them as non-discoverable?
		fn=combine_path(dir,fn);
		if (file_stat(fn)->isdir) discover_plugins(fn);
		else if (has_suffix(fn,".pike") && !plugins[fn])
		{
			//Try to compile the plugin. If that succeeds, look for a constant plugin_active_by_default;
			//if it's found, that's the default active state. (Normally, if it's present, it'll be 1.)
			program compiled=probe_plugin(fn);
			//Note that if compilation fails, this will still put in an entry. It'd then require manual
			//overriding to say "go and activate this"; the active_by_default marker will no longer work.
			plugins[fn]=(["active":compiled && compiled->plugin_active_by_default]);
		}
	}
}

constant plugins_configure_plugins="_Configure";
class configure_plugins
{
	inherit configdlg;
	mapping(string:mixed) windowprops=(["title":"Activate/deactivate plugins"]);
	constant allow_rename=0;
	constant persist_key="plugins/status";
	constant bools=({"active"});

	void create() {discover_plugins("plugins"); ::create(); win->cfg->hide();}

	GTK2.Widget make_content()
	{
		return GTK2.Vbox(0,10)
			->pack_start(two_column(({
				//This would be a great use for the "different internal and display" theory; there's no need to show
				//the full path in the list box. But this won't work with the descr_key, as we want to show _less_ info.
				"Filename",win->kwd=GTK2.Entry(),
				"",win->active=GTK2.CheckButton("Activate on startup"),
				"",win->activate=GTK2.Button("Activate/Reload"),
				"",win->deactivate=GTK2.Button("Deactivate"),
			})),0,0,0)
			->pack_start(win->cfg=GTK2.Frame("<config>")->add(win->cfg_ef=GTK2.Entry()),0,0,0)
			->add(GTK2.Frame("Plugin documentation")->add(GTK2.ScrolledWindow()
				->set_policy(GTK2.POLICY_AUTOMATIC,GTK2.POLICY_AUTOMATIC)
				->add(win->docs=MultiLineEntryField()->set_editable(0)->set_wrap_mode(GTK2.WRAP_WORD))
			))
		;
	}

	void load_content(mapping(string:mixed) info)
	{
		string docstring="";
		win->cfg->hide(); m_delete(win,"c_p_k");
		if (string fn=selecteditem())
		{
			docstring="(unable to compile, see source)";
			if (program p=probe_plugin(fn))
			{
				docstring=String.trim_all_whites(p->docstring || "(undocumented, see source)");
				if (p->plugin_active_by_default) docstring+="\n\nActive by default.";
				string provides=Array.uniq(Program.all_inherits(p)->provides-({0}))*", ";
				if (provides!="") docstring+="\n\nProvides: "+provides;
				//Can also list any other "obvious" info, eg menu_label. Not sure how best to
				//collect that, though, and it won't cope with plugins that create two of them.
				//Not that the double-inherit is a problem; there are no standard plugins doing
				//any double-inheriting other than for the menu, and that may or may not be
				//deemed important enough to formally support.

				//Optionally provide a single configuration field.
				if (p->config_persist_key && p->config_description)
				{
					win->cfg->show()->set_label(p->config_description);
					win->cfg_ef->set_text(persist[win->c_p_k=p->config_persist_key] || "");
				}
			}
		}
		//The MLE wraps, so we remove all newlines that aren't doubled.
		docstring=replace((docstring/"\n\n")[*],"\n"," ")*"\n\n";
		win->docs->set_text(String.trim_all_whites(docstring));
	}

	void save_content(mapping(string:mixed) info)
	{
		if (win->c_p_k) persist[win->c_p_k]=win->cfg_ef->get_text();
	}

	void sig_activate_clicked() {if (string sel=selecteditem()) build(sel);}

	void sig_deactivate_clicked()
	{
		if (!G->G->commands->unload) return;
		string sel=selecteditem(); if (!sel) return;
		//TODO: Don't tie this to a plugin-provided command. However, unload() can't go into
		//globals.pike for the same reason build() couldn't: it uses say(). So maybe there
		//needs to be another file called plugins.pike which handles all this? Or else just
		//have it all here in window.pike. There's no reason to make it a separate file, bar
		//the size of this one; but then, there's no reason to make connection.pike separate
		//either, now, but it's more logical to keep that separate (even though it does make
		//an annoying deploop).
		G->G->commands->unload("confirm "+sel,current_subw());
	}
}

void makewindow()
{
	win->mainwindow=mainwindow=GTK2.Window(GTK2.WindowToplevel);
	mainwindow->set_title("Gypsum");
	mainwindow->set_default_size(800,500);
	GTK2.AccelGroup accel=G->G->accel=GTK2.AccelGroup();
	G->G->plugin_menu=([]); //Note that, as of 20141219, this no longer needs to be initialized here in makewindow(). Is there a better place for it? It doesn't hurt here, but it's illogical.
	mainwindow->add_accel_group(accel)->add(GTK2.Vbox(0,0)
		->pack_start(GTK2.MenuBar()
			//Note these odd casts: set_submenu() expects a GTK2.Widget, and for some
			//reason won't accept a GTK2.Menu, which is a subclass of Widget.
			->add(GTK2.MenuItem("_File")->set_submenu((object)GTK2.Menu()))
			->add(GTK2.MenuItem("_Options")->set_submenu((object)GTK2.Menu()))
			->add(GTK2.MenuItem("_Plugins")->set_submenu((object)GTK2.Menu()))
			->add(GTK2.MenuItem("_Help")->set_submenu((object)GTK2.Menu()))
		,0,0,0)
		->add(win->notebook=GTK2.Notebook())
		->pack_end(win->statusbar=GTK2.Hbox(0,0)->set_size_request(0,-1),0,0,0) //May be worth making the size request optional. Some might want a shrinking statusbar, some might want to ensure they see everything.
	);
	call_out(mainwindow->present,0); //After any plugin windows have loaded, grab - or attempt to grab - focus back to the main window.
	::makewindow();
}

void create(string name)
{
	add_gypsum_constant("say",say);
	add_gypsum_constant("build",build);
	G->G->connection->say=say;
	if (!win->tabs) win->tabs=({ });
	if (G->G->window) monochrome=G->G->window->monochrome;
	G->G->window=this;
	statustxt->tooltip="Hover a line to see when it happened";
	movablewindow::create(""); //This one MUST be called first, and it's convenient to put a different name in - prevents collisions, other code can reliably find this.
	mainwindow=win->mainwindow; mainwin=win;
	if (!sizeof(win->tabs)) {addtab(); call_out(redraw,0.5,win->tabs[0]);}
	(::create-({movablewindow::create}))(name); //Call all other constructors, in any order.

	if (!win->color_defs)
	{
		win->color_defs=persist["color/sixteen"]; //Note: Assumed to be exactly sixteen arrays of exactly three ints each.
		if (!win->color_defs)
		{
			//Default color definitions: the standard ANSI colors.
			array bits = map(enumerate(8),lambda(int x) {return ({x&1,!!(x&2),!!(x&4)});});
			win->color_defs = (bits[*][*]*127) + (bits[*][*]*255);
			//The strict bitwise definition would have bold black looking black. It should be a bit darker than nonbold white, so we change them around a bit.
			win->color_defs[8] = win->color_defs[7]; win->color_defs[7] = ({192,192,192});
		}
	}
	if (!win->colors) win->colors = Function.splice_call(win->color_defs[*],GTK2.GdkColor); //Note that the @ short form can't replace splice_call here.
	colors=win->colors;

	/* Not quite doing what I want, but it's a start...

	GTK2.ListStore ls=GTK2.ListStore(({"string"}));
	GTK2.EntryCompletion compl=GTK2.EntryCompletion()->set_model(ls)->set_text_column(0)->set_minimum_key_length(2);
	foreach (sort(indices(G->G->commands)),string kwd) ls->set_value(ls->append(),0,"/"+kwd);
	win->tabs[0]->ef->set_completion(compl);
	*/

	//Build or rebuild the menus
	//Note that this code depends on there being four menus: File, Options, Plugins, Help.
	//If that changes, compatibility code will be needed.
	array(GTK2.Menu) submenus=mainwindow->get_child()->get_children()[0]->get_children()->get_submenu();
	foreach (submenus,GTK2.Menu submenu) foreach (submenu->get_children(),GTK2.MenuItem w) {w->destroy(); destruct(w);}
	//Neat hack: Build up a mapping from a prefix like "options" (the part before the underscore
	//in the constant name) to the submenu object it should be appended to.
	[menus->file,menus->options,menus->plugins,menus->help] = submenus;
	foreach (sort(indices(this_program)),string key) if (object menu=sscanf(key,"%s_%s",string pfx,string name) && name && menus[pfx])
	{
		program me=this_program; //Note that this_program[key] doesn't work in Pike 7.8.866 due to a bug fixed in afa24a (8.0 branch only).
		array|string info=me[key]; //The workaround is to assign this_program to a temporary and index that instead.
		GTK2.MenuItem item=arrayp(info)
			? GTK2.MenuItem(info[0])->add_accelerator("activate",G->G->accel,info[1],info[2],GTK2.ACCEL_VISIBLE)
			: GTK2.MenuItem(info); //String constants are just labels; arrays have accelerator key and modifiers.
		item->show()->signal_connect("activate",this[name]);
		menu->add(item);
	}
	//Recreate plugin menu items in name order
	foreach (sort(indices(G->G->plugin_menu)),string name) if (mapping mi=G->G->plugin_menu[name])
		if (!mi->menuitem) mi->self->make_menuitem(name);

	//Scan for plugins now that everything else is initialized.
	mapping(string:mapping(string:mixed)) plugins=persist->setdefault("plugins/status",([]));
	//Compat: Pull in the list from plugins/more.pike's config
	if (mapping old=persist["plugins/more/list"])
	{
		foreach (old;string fn;mapping info) plugins[fn-"-more"]=info; //Cheat a bit, remove any instance of -more from the filename
		m_delete(persist,"plugins/more/list"); //Delete at the end, just in case something goes wrong
	}
	//Prune the plugins list to only what actually exists
	foreach (plugins;string fn;) if (!file_stat(fn)) m_delete(plugins,fn);
	discover_plugins("plugins");
	persist->save(); //Autosave (even if nothing's changed, currently)
	if (!win->plugin_mtime) win->plugin_mtime=([]);
	foreach (sort(indices(plugins)),string fn)
	{
		//TODO: Should the configure_plugins dlg also manipulate plugin_mtime?
		if (plugins[fn]->active)
		{
			int mtime=file_stat(fn)->mtime;
			if (mtime!=win->plugin_mtime[fn] && !catch {G->bootstrap(fn);}) win->plugin_mtime[fn]=mtime;
		}
		else m_delete(win->plugin_mtime,fn);
	}
	settabs(win->tabs[0]->charwidth);
}

int sig_mainwindow_destroy() {exit(0);}

constant file_save_html="Save as _HTML";
void save_html()
{
	object dlg=GTK2.FileChooserDialog("Save scrollback as HTML",mainwindow,
		GTK2.FILE_CHOOSER_ACTION_SAVE,({(["text":"Save","id":GTK2.RESPONSE_OK]),(["text":"Cancel","id":GTK2.RESPONSE_CANCEL])})
	)->show_all();
	dlg->signal_connect("response",save_html_response);
	dlg->set_current_folder(".");
}

void save_html_response(object self,int btn)
{
	string fn=self->get_filename();
	self->destroy();
	if (btn!=GTK2.RESPONSE_OK) return;
	mapping(string:mixed) subw=current_subw();
	Stdio.File f=Stdio.File(fn,"wct");
	f->write("<!doctype html><html><head><meta charset=\"UTF-8\"><title>Gypsum session - Save as HTML</title><style type=\"text/css\">\n");
	//Write out styles, foreground and background
	foreach (colors;int i;object col) f->write(sprintf("%%{.%%sg%d {%%scolor: #%02X%02X%02X}\n%%}",i,@col->rgb()),({({"f",""}),({"b","background-"})}));
	f->write("</style></head><body class=bg0><hr><pre><code>\n");
	foreach (subw->lines;int lineno;array line)
	{
		f->write("<span title=\"%s\">",hovertext(subw,lineno));
		for (int i=1;i<sizeof(line);i+=2)
			f->write("<span class='fg%d bg%d'>%s</span>",line[i]&15,(line[i]>>16)&15,string_to_utf8(Parser.encode_html_entities(line[i+1])));
		f->write("</span>\n");
	}
	f->write("</code></pre><hr></body></html>\n");
	f->close();
	MessageBox(0,GTK2.MESSAGE_INFO,GTK2.BUTTONS_OK,"Saved to "+fn,mainwindow);
}

constant file_closewindow="E_xit";
int closewindow()
{
	//Slight hack: Save the tab list every time a close is attempted.
	//This really ought to be either actual closings only, or every time the tab list changes.
	if (persist["reopentabs"]&1) persist["savedtablist"]=win->tabs->world-({0});
	int confirmclose=persist["window/confirmclose"];
	if (confirmclose==-1) exit(0);
	int conns=sizeof((win->tabs->connection-({0}))->sock-({0})); //Number of active connections (would look tidier with ->? but I need to support 7.8).
	if (!conns && !confirmclose) exit(0);
	confirm(0,"You have "+conns+" active connection(s), really quit?",mainwindow,exit,0);
	return 1; //Used as the delete-event, so it should return 1 for that.
}

constant file_connect_menu="_Connect";
class connect_menu
{
	inherit configdlg;
	constant strings=({"name","host","logfile","descr","writeme"});
	constant ints=({"port"});
	constant bools=({"use_ka"});
	constant persist_key="worlds";

	mapping(string:mixed) windowprops=(["title":"Connect to a world"]);
	void create() {::create();} //Pass on no args

	void load_content(mapping(string:mixed) info)
	{
		if (!info->port) {info->port=23; win->port->set_text("23");}
		if (undefinedp(info->use_ka)) win->use_ka->set_active(1);
	}

	void sig_pb_connect_clicked()
	{
		sig_pb_save_clicked();
		string kwd=selecteditem();
		if (!kwd) return;
		connect(kwd,0);
		win->mainwindow->destroy();
	}

	GTK2.Widget make_content()
	{
		return GTK2.Vbox(0,10)
			->pack_start(two_column(({
				"Keyword",win->kwd=GTK2.Entry(),
				"Name",win->name=GTK2.Entry(),
				"Host name",win->host=GTK2.Entry(),
				"Port",win->port=GTK2.Entry(),
				"Auto-log",win->logfile=GTK2.Entry(),
				"",win->use_ka=GTK2.CheckButton("Use keep-alive"), //No separate label, but don't span - keep it in the second column.
			})),0,0,0)
			->add(GTK2.Frame("Description")->add(
				win->descr=MultiLineEntryField()->set_size_request(250,70)
			))
			->add(GTK2.Frame("Text to output upon connect")->add(
				win->writeme=MultiLineEntryField()->set_size_request(250,70)
			))
			->pack_start(GTK2.HbuttonBox()->add(
				win->pb_connect=GTK2.Button((["label":"Save and C_onnect","use-underline":1]))
			),0,0,0)
		;
	}
}

constant file_disconnect_menu="_Disconnect";
void disconnect_menu(object self) {connect(0,0);}

int sig_notebook_switch_page(object self,mixed segfault,int page,mixed otherarg)
{
	//CAUTION: The first GTK-supplied parameter is a pointer to a GtkNotebookPage, and in
	//Pike versions prior to 8.0.4 and 7.8.872 (including 7.8.866 which I support), it
	//comes through as a Pike object - which it isn't. Doing *ANYTHING* with that value
	//is liable to segfault Pike. However, since it's a pretty much useless value anyway,
	//ignore it and just use 'page' (which is the page index). I'm keeping this here as
	//sort of documentation, hence it includes an 'otherarg' arg (which I'm not using -
	//an additional argument to signal_connect/gtksignal would provide that value here)
	//and names all the arguments. All I really need is 'page'. End caution.
	mapping subw=win->tabs[page];
	subw->activity=0;
	//Reset the cursor pos based on where it was last time focus entered the EF. This is
	//distinctly weird, but it prevents the annoying default behaviour of selecting all.
	if (subw->cursor_pos_last_focus_in) subw->ef->select_region(@subw->cursor_pos_last_focus_in);
	//Note that this, while not technically part of the boom2 bugfix, is fixed in the
	//same Pike versions, and there's really not a lot of point separating them.
	#if constant(COMPAT_BOOM2)
	call_out(lambda(int page,mapping subw) {
	#endif
		//NOTE: Doing this work inside the signal handler can segfault Pike, so do it
		//on the backend. (Probably related to the above caution.) The same applies
		//if the args are omitted (making this a closure).
		win->notebook->set_tab_label_text(subw->page,subw->tabtext);
		if (win->notebook->get_current_page()==page) subw->ef->grab_focus();
		if (subw->cursor_pos_last_focus_in) subw->ef->select_region(@subw->cursor_pos_last_focus_in);
		call_out(redraw,0,subw);
		runhooks("switchtabs",0,subw);
	#if constant(COMPAT_BOOM2)
	},0,page,subw);
	#endif
}

//Reset the urgency hint when focus arrives.
//Ideally I want to do this at the exact moment when mainwindow->is_active()
//changes from 0 to 1, but I can't find that. In lieu of such an event, I'm
//going for something that fires on various focus movements within the main
//window; it'll never fire when we don't have window focus, so it's safe.
void sig_mainwindow_focus_in_event() {mainwindow->set_urgency_hint(0);}
