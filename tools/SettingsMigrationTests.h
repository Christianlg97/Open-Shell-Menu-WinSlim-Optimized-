#pragma once

#include "../Src/Lib/SettingsMigration.h"

// Included after Require(). Never opens Software\OpenShell: the registry part
// uses a volatile scratch key that is deleted at the end (or at logoff).
static void CheckSettingsMigration()
{
	const std::wstring system=L"C:\\Windows\\System32";
	// Saved by 4.4.1007 (current account before the manual fix), plus edge cases
	std::vector<std::wstring> lines={
		L"Item17.Command=separator",
		L"Item18.Link=C:\\Windows\\system32\\cmd.exe",
		L"Item18.Label=CMD",
		L"Item18.Settings=OPEN_UP_CHILDREN",
		L"Item19.Link=C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
		L"Item19.Settings=OPEN_UP_CHILDREN",
		L"Item20.Command=run",
		L"Item21.Link=C:\\Tools\\cmd.exe",
		L"Item22.Link=C:\\Windows\\System32\\notepad.exe",
		L"Item23.Link = Console | C:\\WINDOWS\\SYSTEM32\\CMD.EXE",
		L"Item24.Link=C:\\Windows\\System32\\cmd.exe",
		L"Item24.Settings=open_up|run_as_admin",
		L";Item25.Link=C:\\Windows\\System32\\cmd.exe",
		L"Item26.Link=C:\\Windows\\System32\\notepad.exe",
		L"Item26.Settings=",
		L"Item26.Link=C:\\Windows\\System32\\cmd.exe",
		L"Item27.Link=C:\\Windows\\System32\\cmd.exe",
		L"Item27.Settings=SPLIT",
		L"Item27.Settings = OPEN_UP ; ",
		L"",
	};
	const std::vector<std::wstring> original=lines;
	Require(OpenShellMigration::ElevateConsoleItems(lines,system)==5,"Wrong number of console items migrated");
	const std::vector<std::wstring> expected={
		L"Item17.Command=separator",
		L"Item18.Link=C:\\Windows\\system32\\cmd.exe",
		L"Item18.Label=CMD",
		L"Item18.Settings=OPEN_UP_CHILDREN|RUN_AS_ADMIN",
		L"Item19.Link=C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
		L"Item19.Settings=OPEN_UP_CHILDREN|RUN_AS_ADMIN",
		L"Item20.Command=run",
		L"Item21.Link=C:\\Tools\\cmd.exe",
		L"Item22.Link=C:\\Windows\\System32\\notepad.exe",
		L"Item23.Link = Console | C:\\WINDOWS\\SYSTEM32\\CMD.EXE",
		L"Item23.Settings=RUN_AS_ADMIN",
		L"Item24.Link=C:\\Windows\\System32\\cmd.exe",
		L"Item24.Settings=open_up|run_as_admin",
		L";Item25.Link=C:\\Windows\\System32\\cmd.exe",
		L"Item26.Link=C:\\Windows\\System32\\notepad.exe",
		L"Item26.Settings=RUN_AS_ADMIN",
		L"Item26.Link=C:\\Windows\\System32\\cmd.exe",
		L"Item27.Link=C:\\Windows\\System32\\cmd.exe",
		L"Item27.Settings=SPLIT",
		L"Item27.Settings = OPEN_UP|RUN_AS_ADMIN",
		L"",
	};
	Require(lines==expected,"Console migration changed the wrong lines");
	Require(OpenShellMigration::ElevateConsoleItems(lines,system)==0 && lines==expected,"Console migration is not idempotent");
	std::vector<std::wstring> other(original.begin(),original.begin()+1);
	Require(OpenShellMigration::ElevateConsoleItems(other,system)==0 && other.size()==1,"Menu without consoles was changed");

	wchar_t systemDir[MAX_PATH];
	UINT length=GetSystemDirectoryW(systemDir,MAX_PATH);
	Require(length>0 && length<MAX_PATH,"No system directory");
	std::vector<std::wstring> expanded={L"Item1.Link=%SystemRoot%\\System32\\cmd.exe"};
	Require(OpenShellMigration::ElevateConsoleItems(expanded,std::wstring(systemDir,length))==1 && expanded.size()==2 &&
		expanded[1]==L"Item1.Settings=RUN_AS_ADMIN","Environment variables in links were not expanded");

	const wchar_t terminated[]=L"a\0b\0";
	auto entries=OpenShellMigration::SplitMultiString(terminated,_countof(terminated));
	Require(entries.size()==3 && OpenShellMigration::JoinMultiString(entries,true)==std::wstring(terminated,_countof(terminated)),"REG_MULTI_SZ round trip changed bytes");
	const wchar_t open[]={L'a',0,L'b'};
	entries=OpenShellMigration::SplitMultiString(open,_countof(open));
	Require(entries.size()==2 && OpenShellMigration::JoinMultiString(entries,false)==std::wstring(open,_countof(open)),"Unterminated REG_MULTI_SZ changed");

	wchar_t keyPath[64];
	swprintf_s(keyPath,L"Software\\WinSlimCoreTests-%u",GetCurrentProcessId());
	HKEY key=NULL;
	Require(RegCreateKeyExW(HKEY_CURRENT_USER,keyPath,0,NULL,REG_OPTION_VOLATILE,KEY_ALL_ACCESS,NULL,&key,NULL)==ERROR_SUCCESS,"No volatile test key");
	std::wstring stored=OpenShellMigration::JoinMultiString(original,true);
	Require(RegSetValueExW(key,L"MenuItems7",0,REG_MULTI_SZ,(const BYTE*)stored.data(),(DWORD)(stored.size()*sizeof(wchar_t)))==ERROR_SUCCESS,"No test value");
	const wchar_t legacy[]=L"Item1.Link=C:\\Windows\\System32\\cmd.exe";
	Require(RegSetValueExW(key,L"Legacy",0,REG_SZ,(const BYTE*)legacy,sizeof(legacy))==ERROR_SUCCESS,"No legacy test value");
	Require(OpenShellMigration::MigrateMenuItems(key,L"MenuItems7",system)==ERROR_SUCCESS,"Registry migration failed");
	Require(OpenShellMigration::MigrateMenuItems(key,L"Legacy",system)==ERROR_SUCCESS,"Legacy REG_SZ value was not skipped");
	Require(OpenShellMigration::MigrateMenuItems(key,L"Missing",system)==ERROR_SUCCESS,"Missing value was reported as an error");
	std::wstring wanted=OpenShellMigration::JoinMultiString(expected,true);
	std::vector<wchar_t> buffer(wanted.size()+16,0xFFFF);
	DWORD type=0,size=(DWORD)(buffer.size()*sizeof(wchar_t));
	Require(RegQueryValueExW(key,L"MenuItems7",NULL,&type,(BYTE*)buffer.data(),&size)==ERROR_SUCCESS && type==REG_MULTI_SZ &&
		std::wstring(buffer.data(),size/sizeof(wchar_t))==wanted,"Registry value was not migrated byte for byte");
	wchar_t legacyRead[_countof(legacy)+8]={};
	size=sizeof(legacyRead);
	Require(RegQueryValueExW(key,L"Legacy",NULL,&type,(BYTE*)legacyRead,&size)==ERROR_SUCCESS && type==REG_SZ && wcscmp(legacyRead,legacy)==0,"Legacy value changed");
	RegCloseKey(key);
	Require(RegDeleteTreeW(HKEY_CURRENT_USER,keyPath)==ERROR_SUCCESS,"Volatile test key cleanup failed");
	std::cout << "Saved CMD/PowerShell items gain RUN_AS_ADMIN once; other settings are untouched" << std::endl;
}
