#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <string>
#include <vector>
#include <iostream>
#include "../Src/Lib/RustCore.h"
#include "../Src/Lib/CacheMaintenance.h"

static void Require(bool passed, const char *message)
{
	if (!passed) { std::cerr << message << std::endl; ExitProcess(1); }
}

static void CheckCacheMaintenance()
{
	wchar_t temp[MAX_PATH],base[MAX_PATH];
	DWORD length=GetTempPathW(MAX_PATH,temp);
	Require(length>0 && length<MAX_PATH,"No temporary directory");
	Require(GetTempFileNameW(temp,L"osc",0,base)!=0,"No isolated cache test path");
	Require(DeleteFileW(base) && CreateDirectoryW(base,NULL),"No isolated cache test directory");
	std::wstring folder=std::wstring(base)+L"\\OpenShell";
	Require(CreateDirectoryW(folder.c_str(),NULL)!=FALSE,"No isolated OpenShell directory");
	auto path=[&](const wchar_t *name) { return folder+L"\\"+name; };
	auto exists=[&](const wchar_t *name) { return GetFileAttributesW(path(name).c_str())!=INVALID_FILE_ATTRIBUTES; };
	auto create=[&](const wchar_t *name)
	{
		OpenShellCache::Handle file(CreateFileW(path(name).c_str(),GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL));
		Require(file.Valid(),"Could not create isolated cache fixture");
		DWORD written=0;
		Require(WriteFile(file,"keep",4,&written,NULL) && written==4,"Could not write cache fixture");
	};
	for (const wchar_t *name:OpenShellCache::Files) create(name);
	create(L"MenuSettings.xml");
	create(L"StartupLog.txt");
	Require(CreateDirectoryW(path(L"Pinned").c_str(),NULL)!=FALSE,"No test pins directory");
	create(L"Pinned\\Example.lnk");
	Require(OpenShellCache::MaintainFolder(folder.c_str(),L"install-1",false)==ERROR_SUCCESS,"Initial purge failed");
	for (const wchar_t *name:OpenShellCache::Files) Require(!exists(name),"Regenerable cache retained");
	Require(exists(L"MenuSettings.xml") && exists(L"Pinned\\Example.lnk") && exists(L"StartupLog.txt"),"User data removed");
	Require(!exists(OpenShellCache::PendingName),"Successful purge left a pending request");
	create(L"DataCache.db");
	Require(OpenShellCache::MaintainFolder(folder.c_str(),L"install-1",false)==ERROR_SUCCESS && exists(L"DataCache.db"),"Warm cache deleted again");
	{
		OpenShellCache::Handle locked(CreateFileW(path(L"DataCache.db").c_str(),GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL));
		Require(locked.Valid(),"Could not lock test cache");
		Require(OpenShellCache::MaintainFolder(folder.c_str(),L"install-2",false)!=ERROR_SUCCESS,"Locked purge was reported complete");
		Require(exists(OpenShellCache::PendingName) && exists(L"DataCache.db"),"Locked file/request lost");
	}
	Require(OpenShellCache::MaintainFolder(folder.c_str(),L"install-2",false)==ERROR_SUCCESS && !exists(L"DataCache.db"),"Deferred purge did not retry");
	create(L"DataCache.txt");
	create(OpenShellCache::PendingName);
	Require(OpenShellCache::MaintainFolder(folder.c_str(),L"install-2",false)==ERROR_SUCCESS && !exists(L"DataCache.txt"),"VBS request ignored");
	create(L"ModernSettings.dat");
	Require(OpenShellCache::MaintainFolder(folder.c_str(),L"install-2",true)==ERROR_SUCCESS && !exists(L"ModernSettings.dat"),"Forced reinstall purge ignored");
	Require(CreateDirectoryW(path(OpenShellCache::PendingName).c_str(),NULL)!=FALSE,"No invalid marker fixture");
	create(L"DataCache.db");
	Require(OpenShellCache::MaintainFolder(folder.c_str(),L"install-3",false)==ERROR_ACCESS_DENIED && exists(L"DataCache.db"),"Invalid pending marker accepted");
	Require(RemoveDirectoryW(path(OpenShellCache::PendingName).c_str())!=FALSE,"Invalid marker removal failed");
	Require(OpenShellCache::MaintainFolder(base,L"install-3",true)==ERROR_INVALID_NAME,"Arbitrary directory accepted for cleanup");
	Require(OpenShellCache::MaintainFolder(folder.c_str(),L"install-3",false)==ERROR_SUCCESS,"Final purge failed");
	for (const wchar_t *name:{L"MenuSettings.xml",L"StartupLog.txt",L"Pinned\\Example.lnk",OpenShellCache::StateName,L"CacheMaintenance.lock"})
		Require(DeleteFileW(path(name).c_str())!=FALSE,"Test fixture cleanup failed");
	Require(RemoveDirectoryW(path(L"Pinned").c_str()) && RemoveDirectoryW(folder.c_str()) && RemoveDirectoryW(base),"Test directory cleanup failed");
	std::cout << "Cache purge, locked-file retry and user data preservation checks passed" << std::endl;
}

#include "MenuPerformanceTests.h"

int main()
{
	static_assert(sizeof(wchar_t)==2,"The C ABI uses UTF-16 code units");
	CheckCacheMaintenance();
	CheckSearchCatalogs();
	CheckFolderBatches();
	Require(WinSlimCheckedSpan(-1,2,32767,UINT64_MAX)==UINT64_MAX,"Negative cache length accepted");
	Require(WinSlimCheckedSpan(32768,2,32767,UINT64_MAX)==UINT64_MAX,"Oversized string accepted");
	Require(WinSlimCheckedSpan(8,2,32767,15)==UINT64_MAX,"Truncated record accepted");
	Require(WinSlimCheckedSpan(8,2,32767,16)==16,"Valid cache span rejected");
	Require(WinSlimBitmapBytes(65536,65537)==0,"Bitmap multiplication overflow accepted");
	Require(WinSlimBitmapBytes(48,48)==9216,"Valid bitmap rejected");
	unsigned char valid[]={4,0,1,2,0,0}, truncated[]={4,0,1,2}, invalid[]={1,0,0,0};
	Require(WinSlimValidatePidl(valid,sizeof(valid))==1,"Valid PIDL rejected");
	Require(WinSlimValidatePidl(truncated,sizeof(truncated))==0,"Unterminated PIDL accepted");
	Require(WinSlimValidatePidl(invalid,sizeof(invalid))==0,"Invalid PIDL block accepted");
	Require(WinSlimValidatePidl(NULL,2)==0,"Null PIDL accepted");
	const wchar_t input[]=L" ; comment\r\n Name=M\x00FAsica \t\nLast=1\0";
	std::vector<wchar_t> text(input,input+_countof(input));
	size_t cursor=0, first=0, last=0;
	Require(WinSlimNextLine(text.data(),text.size(),&cursor,&first,&last)==1,"First line missing");
	text[last]=0;
	Require(wcscmp(text.data()+first,L"Name=M\x00FAsica")==0,"Whitespace/Unicode parsing regression");
	Require(WinSlimNextLine(text.data(),text.size(),&cursor,&first,&last)==1,"Second line missing after in-place termination");
	text[last]=0;
	Require(wcscmp(text.data()+first,L"Last=1")==0,"Last line corrupted");
	Require(WinSlimNextLine(text.data(),text.size(),&cursor,&first,&last)==0,"Parser did not terminate");
	auto matches=[](const std::wstring &query,const std::wstring &name,bool subword)
	{
		return WinSlimMatchText(query.data(),query.size(),name.data(),name.size(),subword?1:0)!=0;
	};
	Require(matches(L"musica",L"M\x00DASICA",true),"Accent-insensitive matching changed");
	Require(matches(L"win power",L"Windows PowerShell",false),"Multiple token matching changed");
	Require(!matches(L"shell",L"Windows PowerShell",false),"Word boundary ignored");
	Require(matches(L"shell",L"Windows PowerShell",true),"Substring matching changed");
	Require(matches(std::wstring(200,L'x'),std::wstring(200,L'x'),true),"Long query was truncated");
	Require(matches(L"\"visual studio\"",L"Visual Studio Code",false),"Quoted phrase was split into words");
	Require(matches(L"\"studio code\" vis",L"Visual Studio Code",false),"Quoted phrase with another token failed");
	Require(!matches(L"\"visual code\"",L"Visual Studio Code",false),"Quoted phrase matched out of order");
	Require(matches(L"\"o co\"",L"Visual Studio Code",true),"Quoted substring failed");
	Require(!matches(L"\"o co\"",L"Visual Studio Code",false),"Quoted phrase ignored word boundaries");
	Require(matches(L"\"visual",L"Visual Studio Code",false),"Unterminated quote was not closed at the end");
	// Compare the C ABI against the user's Windows locale, rather than assuming
	// invariant or English collation in the Rust implementation.
	for (const wchar_t *value:{L"I",L"\x0130",L"\x0131",L"\x00DF",L"\x00E9"})
	{
		bool expected=FindNLSStringEx(LOCALE_NAME_USER_DEFAULT,FIND_FROMSTART|LINGUISTIC_IGNORECASE|LINGUISTIC_IGNOREDIACRITIC,
			value,-1,L"i",1,NULL,NULL,NULL,0)>=0;
		Require(matches(L"i",value,true)==expected,"User locale matching changed across the C ABI");
	}
	std::cout << "Native C++/core ABI regression checks passed" << std::endl;
	return 0;
}
