#pragma once

#include <stdint.h>
#include <stddef.h>

// Borrowed buffers remain owned by C++. No CString, COM object, allocator or
// exception crosses this C ABI. Every export contains unwinding Rust panics.
#ifdef WINSLIM_USE_RUST
extern "C"
{
uint64_t __cdecl WinSlimCheckedSpan(int count, uint32_t unit, uint32_t limit, uint64_t remaining);
uint32_t __cdecl WinSlimBitmapBytes(int width, int height);
int __cdecl WinSlimValidatePidl(const unsigned char *data, size_t size);
int __cdecl WinSlimNextLine(const wchar_t *text, size_t length, size_t *cursor, size_t *start, size_t *end);
int __cdecl WinSlimMatchText(const wchar_t *search, size_t searchLength, const wchar_t *text, size_t textLength, int subword);
}

#pragma comment(lib, "winslim_core.lib")
#pragma comment(lib, "userenv.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "ntdll.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "dbghelp.lib")
#else
// Compatibility implementation for the original Windows 7/8 toolchain. The
// WinSlim build enables the Rust implementations of the same bounded contract.
inline uint64_t WinSlimCheckedSpan(int count, uint32_t unit, uint32_t limit, uint64_t remaining)
{
	if (count<0 || !unit || (uint32_t)count>limit) return UINT64_MAX;
	uint64_t bytes=(uint64_t)count*unit;
	return bytes<=remaining?bytes:UINT64_MAX;
}
inline uint32_t WinSlimBitmapBytes(int width, int height)
{
	return width>0 && height>0 && width<=4096 && height<=4096?(uint32_t)width*height*4:0;
}
inline int WinSlimValidatePidl(const unsigned char *data, size_t size)
{
	if (!data || size<2 || size>65536) return 0;
	size_t at=0;
	while (at+2<=size)
	{
		size_t length=data[at]|(size_t(data[at+1])<<8);
		if (!length) return at+2==size;
		if (length<2 || length>size-at) return 0;
		at+=length;
	}
	return 0;
}
inline int WinSlimNextLine(const wchar_t *text, size_t length, size_t *cursor, size_t *start, size_t *end)
{
	if ((!text && length) || length>16*1024*1024+1 || !cursor || !start || !end || *cursor>length) return -1;
	size_t at=*cursor;
	while (at<length && text[at])
	{
		size_t first=at;
		while (at<length && text[at] && text[at]!='\r' && text[at]!='\n') at++;
		size_t last=at;
		while (at<length && (text[at]=='\r' || text[at]=='\n')) at++;
		while (first<last && (text[first]==' ' || text[first]=='\t')) first++;
		while (last>first && (text[last-1]==' ' || text[last-1]=='\t')) last--;
		if (first<last && text[first]!=';') { *start=first; *end=last; *cursor=at; return 1; }
	}
	*cursor=length;
	return 0;
}
inline int WinSlimMatchText(const wchar_t *search, size_t searchLength, const wchar_t *text, size_t textLength, int subword)
{
	if ((!search && searchLength) || !text || !textLength || searchLength>16*1024*1024+1 || textLength>16*1024*1024+1) return 0;
	for (size_t at=0;at<searchLength;)
	{
		while (at<searchLength && search[at]==' ') at++;
		size_t first=at;
		while (at<searchLength && search[at]!=' ') at++;
		if (first==at) continue;
		bool found=false;
		for (size_t pos=0;pos<textLength;)
		{
			if (!subword) while (pos<textLength && wcschr(L" \t.,$&[]{}();|",text[pos])) pos++;
			if (pos<textLength && FindNLSStringEx(LOCALE_NAME_USER_DEFAULT,(subword?FIND_FROMSTART:FIND_STARTSWITH)|LINGUISTIC_IGNORECASE|LINGUISTIC_IGNOREDIACRITIC,
				text+pos,(int)(textLength-pos),search+first,(int)(at-first),NULL,NULL,NULL,0)>=0) { found=true; break; }
			if (subword) break;
			while (pos<textLength && !wcschr(L" \t.,$&[]{}();|",text[pos])) pos++;
		}
		if (!found) return 0;
	}
	return 1;
}
#endif
