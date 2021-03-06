//NOTE: COMPAT_* options are not set when this file is loaded, and therefore cannot be used.
//(They will exist if the file is reloaded post-startup, but still should not be used.)

object persist=class(string savefn)
{
	//Persistent storage (when this dies, bring it back with a -1/-1 counter on it).
	//It's also undying storage. When it dies, bring it back one way or the other. :)
	/* Usage:
	 * persist["some/string/identifier"]=any_value;
	 * retrieved_value=persist["some/string/identifier"];
	 * old_value=m_delete(persist,"some/string/identifier");
	 * Saves to disk after every change, or on persist->save() calls.
	 * Loads from disk only on initialization - /update this file to reload.
	 * Note that saving is done with a call_out(0), so you can freely batch mutations
	 * without grinding the disk too much - saving will happen next idleness, probably.
	 **/

	/* Idea: Encrypt the file with a password. This isn't high-grade security but might be good for some people.
	string pwd;
	string key=Crypto.SHA256.hash("Gypsum"+string_to_utf8(pwd)+"Gypsum");
	string content=encode_value(data);
	int pad=16-sizeof(content)%16; //Add bytes to make up exact blocks, adding an entire block if necessary.
	content=(string)allocate(pad,pad)+content;
	string enc=Crypto.AES.encrypt(key,content);

	if (catch {
		string dec=Crypto.AES.decrypt(key,enc);
		if (dec[0]>16) throw(1); //Must be incorrect password - the padding signature is damaged.
		dec=dec[dec[0]..]; //Trim off the padding
		data=decode_value(dec);
	}) error("Incorrect password.");
	*/

	mapping(string:mixed) data=([]);
	int saving;

	void create()
	{
		catch //Ignore any errors, just have no saved data.
		{
			mixed decode=decode_value(Stdio.read_file(savefn));
			if (mappingp(decode)) data=decode;
		};
	}

	//Retrievals and mutations work as normal; mutations trigger a save().
	mixed `[](string idx) {return data[idx];}
	mixed `[]=(string idx,mixed val) {save(); return data[idx]=val;}
	mixed _m_delete(string idx) {save(); return m_delete(data,idx);}

	//Like the Python dict method of the same name, will save a default back in if it wasn't defined.
	//Best used with simple defaults such as an empty mapping/array, or a string. Ensures that the
	//persist key will exist and be usefully addressable.
	mixed setdefault(string idx,mixed def)
	{
		mixed ret=data[idx];
		if (undefinedp(ret)) return this[idx]=def;
		return ret;
	}

	void save() {if (!saving) {saving=1; call_out(dosave,0);}}
	
	void dosave()
	{
		if (mixed ex=catch
		{
			Stdio.write_file(savefn+".1",encode_value(data));
			mv(savefn+".1",savefn); //Depends on atomic mv, otherwise this might run into issues.
			saving=0;
		})
		{
			//TODO: Show the "danger state" somewhere on the GUI too.
			werror("Unable to save %s: %s\nWill retry in 60 seconds.\n",savefn,describe_error(ex));
			call_out(dosave,60);
		}
	}
}(".gypsumrc"); //Save file name. May be worth making this configurable somehow. On some platforms, it may be worth storing this into a different directory (eg per-user).

void create()
{
	add_gypsum_constant("persist",persist);
}
