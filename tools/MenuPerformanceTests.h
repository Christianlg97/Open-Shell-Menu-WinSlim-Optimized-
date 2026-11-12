#pragma once

#include "../Src/Lib/SearchCatalog.h"
#include "../Src/Lib/DirectoryChangeBatch.h"
#include <set>

// Included after Require(). These run in CoreTests on the user's next build.
struct CatalogTestItem
{
	std::wstring name,keywords,appId;
	int id,rank,category;
	bool bMetroLink;
	size_t duplicateGroup=0;
	const wchar_t *Name( void ) const { return name.c_str(); }
	bool operator<( const CatalogTestItem &other ) const
	{
		return rank>other.rank || (rank==other.rank && name<other.name);
	}
	int Match( const std::wstring &query ) const
	{
		return name.find(query)!=std::wstring::npos?2:(keywords.find(query)!=std::wstring::npos?1:0);
	}
};

static void CheckSearchCatalogs()
{
	std::vector<CatalogTestItem> items;
	for (int i=0;i<240;i++)
		items.push_back({L"APP "+std::to_wstring(i%17),L"KEY "+std::to_wstring(i%11),
			i%7?L"ID "+std::to_wstring(i%5):L"",i,(i%9)*2,1,(i%13)==0});
	// The first of two duplicate links does not match this keyword. It must
	// not suppress the second one merely because it has the better rank.
	items.push_back({L"DUPLICATE",L"",L"same",240,20,1,false});
	items.push_back({L"DUPLICATE",L"ONLY_SECOND",L"same",241,0,1,false});
	items.push_back({L"UNIQUE",L"",L"unused",242,0,1,false});
	int resolved=0;
	Require(OpenShellSearch::PreparePrograms(items,1,[&](const CatalogTestItem &item)
	{
		resolved++;
		Require(item.name!=L"UNIQUE","Unique program needlessly resolved an AppID");
		return item.appId;
	},[]() { return false; }),"Program catalog preparation failed");
	const int preparedCalls=resolved;
	for (const std::wstring query:{L"APP",L"KEY 1",L"KEY 3",L"ONLY_SECOND",L"UNIQUE",L"MISSING",L""})
	{
		std::vector<int> expected,actual;
		std::map<std::pair<std::wstring,bool>,std::set<std::wstring>> groups;
		for (const auto &item:items)
			if (item.Match(query) && groups[{item.name,item.bMetroLink}].insert(item.appId).second)
				expected.push_back(item.id);
		OpenShellSearch::SelectPrograms(items,1,[&](const CatalogTestItem &item) { return item.Match(query); },
			[&](const CatalogTestItem &item) { actual.push_back(item.id); });
		Require(expected==actual,"Program rank/duplicate/keyword behavior changed");
		if (query==L"ONLY_SECOND") Require(actual==std::vector<int>{241},"Nonmatching duplicate suppressed a keyword hit");
	}
	Require(resolved==preparedCalls,"Query selection called the AppID resolver");
	bool cancel=false;
	Require(!OpenShellSearch::PreparePrograms(items,1,[&](const CatalogTestItem &item)
	{
		cancel=true;
		return item.appId;
	},[&]() { return cancel; }),"Canceled catalog was accepted for publication");

	for (int i=0;i<(int)items.size();i++) items[i].category=(i%3)+2;
	for (const std::wstring query:{L"APP",L"KEY 1",L"MISSING",L""})
	{
		std::vector<CatalogTestItem> matched;
		for (auto item:items)
		{
			if (item.category!=2 && item.category!=3) continue;
			int match=item.Match(query);
			if (!match) continue;
			item.rank=(item.rank&~1)|(match>>1);
			matched.push_back(item);
		}
		std::sort(matched.begin(),matched.end());
		std::vector<int> expected,actual;
		for (const auto &item:matched) expected.push_back(item.id);
		OpenShellSearch::SelectSettings(items,2,3,[&](const CatalogTestItem &item) { return item.Match(query); },
			[&](const CatalogTestItem &item) { actual.push_back(item.id); });
		Require(actual==expected,"Setting name/keyword ranking changed");
		for (const auto &item:items) Require((item.rank&1)==0,"Query mutated immutable catalog ranking");
	}
	std::cout << "Search catalog ordering, duplicates, keywords and cancellation checks passed" << std::endl;
}

static DWORD WINAPI StopFolderBatch( void *event )
{
	Sleep(20);
	SetEvent((HANDLE)event);
	return 0;
}

static void CheckFolderBatches()
{
	wchar_t temp[MAX_PATH],base[MAX_PATH];
	DWORD length=GetTempPathW(MAX_PATH,temp);
	Require(length>0 && length<MAX_PATH && GetTempFileNameW(temp,L"osb",0,base),"No folder-batch test path");
	Require(DeleteFileW(base) && CreateDirectoryW(base,NULL),"No folder-batch test directory");
	std::wstring paths[2]={std::wstring(base)+L"\\A",std::wstring(base)+L"\\B"};
	HANDLE directories[2];
	for (int i=0;i<2;i++)
	{
		Require(CreateDirectoryW(paths[i].c_str(),NULL)!=FALSE,"No watched test folder");
		directories[i]=FindFirstChangeNotificationW(paths[i].c_str(),FALSE,FILE_NOTIFY_CHANGE_FILE_NAME);
		Require(directories[i]!=INVALID_HANDLE_VALUE,"Could not watch test folder");
	}
	HANDLE stop=CreateEventW(NULL,TRUE,FALSE,NULL);
	Require(stop!=NULL,"No stop event");
	auto create=[&](int folder,const wchar_t *name)
	{
		HANDLE file=CreateFileW((paths[folder]+L"\\"+name).c_str(),GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
		Require(file!=INVALID_HANDLE_VALUE,"Could not write watched fixture");
		CloseHandle(file);
	};
	create(0,L"one"); create(1,L"one");
	Require(WaitForMultipleObjects(2,directories,TRUE,2000)==WAIT_OBJECT_0,"Directory events did not arrive");
	DWORD masks[2]={1,2},changed=0;
	int count=2;
	Require(OpenShellFolders::WaitForChanges(stop,directories,masks,count,changed,0) && changed==3,
		"A simultaneous folder change was not batched");
	create(0,L"two");
	Require(WaitForSingleObject(directories[0],2000)==WAIT_OBJECT_0,"Watcher was not rearmed");
	Require(OpenShellFolders::WaitForChanges(stop,directories,masks,count,changed,0) && changed==1,
		"Change after rearming was lost");
	create(1,L"two");
	Require(WaitForSingleObject(directories[1],2000)==WAIT_OBJECT_0,"Second change did not arrive");
	HANDLE stopper=CreateThread(NULL,0,StopFolderBatch,stop,0,NULL);
	Require(stopper!=NULL,"Could not start test cancellation");
	DWORD started=GetTickCount();
	Require(!OpenShellFolders::WaitForChanges(stop,directories,masks,count,changed,5000) && changed==0,
		"Stop did not cancel pending debounce");
	Require(GetTickCount()-started<2000,"Stop waited for the full debounce");
	WaitForSingleObject(stopper,INFINITE);
	CloseHandle(stopper);
	Require(!OpenShellFolders::WaitForChanges(stop,directories,masks,count,changed,0),"Folder notification took priority over stop");
	CloseHandle(stop);
	for (int i=0;i<count;i++) FindCloseChangeNotification(directories[i]);
	for (const auto &path:paths)
	{
		Require(DeleteFileW((path+L"\\one").c_str()) && DeleteFileW((path+L"\\two").c_str()),"Fixture cleanup failed");
		Require(RemoveDirectoryW(path.c_str())!=FALSE,"Watched folder cleanup failed");
	}
	Require(RemoveDirectoryW(base)!=FALSE,"Batch test directory cleanup failed");
	std::cout << "Folder batching, rearming and cancelable debounce checks passed" << std::endl;
}
