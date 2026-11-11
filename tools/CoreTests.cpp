#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <string>
#include <vector>
#include <iostream>
#include "../Src/Lib/RustCore.h"

static void Require(bool passed, const char *message)
{
	if (!passed) { std::cerr << message << std::endl; ExitProcess(1); }
}

int main()
{
	static_assert(sizeof(wchar_t)==2,"The C ABI uses UTF-16 code units");
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
