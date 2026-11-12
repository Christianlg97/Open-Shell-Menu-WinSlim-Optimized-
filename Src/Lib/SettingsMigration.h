// WinSlim: one-time fixes of the current user's saved Start Menu settings.
// Only the named lines of HKCU values change; nothing is deleted or reset.
#pragma once
#include <windows.h>
#include <algorithm>
#include <string>
#include <vector>
#include <cwchar>
#pragma comment(lib,"advapi32.lib")

namespace OpenShellMigration
{
constexpr wchar_t StartMenuKey[]=L"Software\\OpenShell\\StartMenu";
constexpr wchar_t LevelName[]=L"WinSlimSettingsMigration";
// 1: CMD/PowerShell items saved by 4.4.1007 or older lack RUN_AS_ADMIN
constexpr DWORD CurrentLevel=1;
constexpr wchar_t RunAsAdmin[]=L"RUN_AS_ADMIN";
constexpr DWORD MaxValueBytes=1024*1024;

inline bool Blank( wchar_t c ) { return c==L' ' || c==L'\t'; }

// "<item>.<field>=<value>" as CSettingsParser sees it: trimmed, no comments,
// optional blanks around '='. Returns false for any other line.
inline bool SplitLine( const std::wstring &line, std::wstring &item, std::wstring &field, std::wstring &value )
{
	size_t first=0,last=line.size();
	while (first<last && Blank(line[first])) first++;
	while (last>first && Blank(line[last-1])) last--;
	if (first==last || line[first]==L';') return false;
	size_t equal=line.find(L'=',first);
	if (equal==std::wstring::npos || equal>=last) return false;
	size_t keyEnd=equal;
	while (keyEnd>first && Blank(line[keyEnd-1])) keyEnd--;
	size_t dot=line.rfind(L'.',keyEnd);
	if (dot==std::wstring::npos || dot<=first || dot+1>=keyEnd) return false;
	size_t valueStart=equal+1;
	while (valueStart<last && Blank(line[valueStart])) valueStart++;
	item.assign(line,first,dot-first);
	field.assign(line,dot+1,keyEnd-dot-1);
	value.assign(line,valueStart,last-valueStart);
	return true;
}

// Same separators as ParseItemSettings (GetToken with ", \t|;").
inline bool HasToken( const std::wstring &value, const wchar_t *token )
{
	const size_t length=wcslen(token);
	size_t start=0;
	while (start<value.size())
	{
		size_t end=value.find_first_of(L", \t|;",start);
		if (end==std::wstring::npos) end=value.size();
		if (end-start==length && _wcsnicmp(value.c_str()+start,token,length)==0) return true;
		start=end+1;
	}
	return false;
}

// Path used by ParseMenuItem: the text after '|', leading spaces skipped.
inline std::wstring LinkPath( const std::wstring &value )
{
	size_t start=value.find(L'|');
	start=(start==std::wstring::npos)?0:start+1;
	while (start<value.size() && value[start]==L' ') start++;
	std::wstring path=value.substr(start);
	if (path.find(L'%')!=std::wstring::npos)
	{
		wchar_t expanded[MAX_PATH];
		DWORD length=ExpandEnvironmentStringsW(path.c_str(),expanded,MAX_PATH);
		if (length>0 && length<=MAX_PATH) path=expanded;
	}
	return path;
}

// Adds RUN_AS_ADMIN to items whose effective Link is the system CMD or Windows
// PowerShell. systemDir is GetSystemDirectory (no trailing backslash). Other
// lines, their order and empty entries are kept. Returns the items changed.
inline int ElevateConsoleItems( std::vector<std::wstring> &lines, const std::wstring &systemDir )
{
	if (systemDir.empty()) return 0;
	const std::wstring targets[]={systemDir+L"\\cmd.exe",systemDir+L"\\WindowsPowerShell\\v1.0\\powershell.exe"};
	struct Item { std::wstring name; size_t link, settings; };
	std::vector<Item> items;
	std::wstring name,field,value;
	for (size_t i=0;i<lines.size();i++)
	{
		if (!SplitLine(lines[i],name,field,value)) continue;
		bool link=_wcsicmp(field.c_str(),L"Link")==0;
		if (!link && _wcsicmp(field.c_str(),L"Settings")!=0) continue;
		Item *pItem=NULL;
		for (Item &item:items)
			if (_wcsicmp(item.name.c_str(),name.c_str())==0) { pItem=&item; break; }
		if (!pItem)
		{
			items.push_back({name,std::wstring::npos,std::wstring::npos});
			pItem=&items.back();
		}
		// the parser searches from the end: the last line of a key wins
		(link?pItem->link:pItem->settings)=i;
	}
	std::vector<std::pair<size_t,std::wstring>> inserts;
	int changed=0;
	for (const Item &item:items)
	{
		if (item.link==std::wstring::npos || !SplitLine(lines[item.link],name,field,value)) continue;
		std::wstring path=LinkPath(value);
		bool console=false;
		for (const std::wstring &target:targets)
			if (_wcsicmp(path.c_str(),target.c_str())==0) console=true;
		if (!console) continue;
		if (item.settings==std::wstring::npos)
		{
			inserts.emplace_back(item.link+1,item.name+L".Settings="+RunAsAdmin);
		}
		else
		{
			if (!SplitLine(lines[item.settings],name,field,value) || HasToken(value,RunAsAdmin)) continue;
			std::wstring &line=lines[item.settings];
			size_t end=line.size();
			while (end>0 && wcschr(L", \t|;",line[end-1])) end--;
			line.resize(end);
			line+=(line.back()==L'=')?L"":L"|";
			line+=RunAsAdmin;
		}
		changed++;
	}
	// insert from the back so earlier positions stay valid (each link line is distinct)
	std::sort(inserts.begin(),inserts.end(),[](const std::pair<size_t,std::wstring> &a,const std::pair<size_t,std::wstring> &b) { return a.first<b.first; });
	for (size_t i=inserts.size();i>0;i--)
		lines.insert(lines.begin()+inserts[i-1].first,inserts[i-1].second);
	return changed;
}

// REG_MULTI_SZ data <-> entries, keeping every terminator (including the final
// empty entries) so an unchanged value is rewritten byte for byte.
inline std::vector<std::wstring> SplitMultiString( const wchar_t *data, size_t count )
{
	std::vector<std::wstring> entries;
	size_t start=0;
	for (size_t i=0;i<count;i++)
	{
		if (data[i]) continue;
		entries.emplace_back(data+start,i-start);
		start=i+1;
	}
	if (start<count) entries.emplace_back(data+start,count-start);
	return entries;
}
inline std::wstring JoinMultiString( const std::vector<std::wstring> &entries, bool terminated )
{
	std::wstring data;
	for (size_t i=0;i<entries.size();i++)
	{
		data+=entries[i];
		if (terminated || i+1<entries.size()) data.push_back(0);
	}
	return data;
}

// ERROR_SUCCESS: value fixed or nothing to fix. Other codes are retried on the
// next start (the level is not recorded).
inline DWORD MigrateMenuItems( HKEY settings, const wchar_t *valueName, const std::wstring &systemDir )
{
	DWORD type=0,size=0;
	LSTATUS result=RegQueryValueExW(settings,valueName,NULL,&type,NULL,&size);
	if (result==ERROR_FILE_NOT_FOUND) return ERROR_SUCCESS;
	if (result!=ERROR_SUCCESS) return result;
	// legacy REG_SZ or implausible data is left exactly as it is
	if (type!=REG_MULTI_SZ || size%sizeof(wchar_t) || size>MaxValueBytes) return ERROR_SUCCESS;
	std::vector<wchar_t> buffer(size/sizeof(wchar_t)+1,0);
	DWORD read=size;
	result=RegQueryValueExW(settings,valueName,NULL,&type,(BYTE*)buffer.data(),&read);
	if (result!=ERROR_SUCCESS) return result;
	if (type!=REG_MULTI_SZ || read>size || read%sizeof(wchar_t)) return ERROR_SUCCESS;
	size_t count=read/sizeof(wchar_t);
	bool terminated=count>0 && buffer[count-1]==0;
	std::vector<std::wstring> lines=SplitMultiString(buffer.data(),count);
	if (ElevateConsoleItems(lines,systemDir)==0) return ERROR_SUCCESS;
	std::wstring data=JoinMultiString(lines,terminated);
	if (data.size()*sizeof(wchar_t)>MaxValueBytes) return ERROR_SUCCESS;
	return RegSetValueExW(settings,valueName,0,REG_MULTI_SZ,(const BYTE*)data.data(),(DWORD)(data.size()*sizeof(wchar_t)));
}

// Call before the settings are loaded. A user without saved settings gets the
// current profile, so no key is created for them.
inline DWORD MigrateCurrentUser( void )
{
	HKEY root=NULL;
	LSTATUS result=RegOpenKeyExW(HKEY_CURRENT_USER,StartMenuKey,0,KEY_QUERY_VALUE|KEY_SET_VALUE|KEY_WOW64_64KEY,&root);
	if (result==ERROR_FILE_NOT_FOUND) return ERROR_SUCCESS;
	if (result!=ERROR_SUCCESS) return result;
	DWORD level=0,type=0,size=sizeof(level);
	if (RegQueryValueExW(root,LevelName,NULL,&type,(BYTE*)&level,&size)==ERROR_SUCCESS && type==REG_DWORD && size==sizeof(level) && level>=CurrentLevel)
	{
		RegCloseKey(root);
		return ERROR_SUCCESS;
	}
	HKEY settings=NULL;
	result=RegOpenKeyExW(root,L"Settings",0,KEY_QUERY_VALUE|KEY_SET_VALUE|KEY_WOW64_64KEY,&settings);
	if (result==ERROR_SUCCESS || result==ERROR_FILE_NOT_FOUND)
	{
		// same fallback as OpenSettingsKeys: old versions kept the values in the parent key
		wchar_t system[MAX_PATH];
		UINT length=GetSystemDirectoryW(system,MAX_PATH);
		result=(length>0 && length<MAX_PATH)?MigrateMenuItems(settings?settings:root,L"MenuItems7",std::wstring(system,length)):ERROR_PATH_NOT_FOUND;
		if (settings) RegCloseKey(settings);
	}
	if (result==ERROR_SUCCESS)
	{
		level=CurrentLevel;
		result=RegSetValueExW(root,LevelName,0,REG_DWORD,(const BYTE*)&level,sizeof(level));
	}
	RegCloseKey(root);
	return result;
}
}
