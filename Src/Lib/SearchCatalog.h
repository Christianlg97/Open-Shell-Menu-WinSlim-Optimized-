#pragma once

#include <algorithm>
#include <cwchar>
#include <map>
#include <string>
#include <utility>
#include <vector>

// Pure catalog algorithms, shared with the native regression tests. All Shell
// work belongs to the publisher; selecting results only reads immutable items.
namespace OpenShellSearch
{
	template<class Item, class Resolve, class Cancelled>
	bool PreparePrograms( std::vector<Item> &items, int category, Resolve resolve, Cancelled cancelled )
	{
		std::sort(items.begin(),items.end());
		struct NameGroup
		{
			size_t first;
			std::map<std::wstring,size_t> appIds;
		};
		std::map<std::pair<std::wstring,bool>,NameGroup> groups;
		size_t nextGroup=0;
		for (size_t i=0;i<items.size();i++)
		{
			if (cancelled()) return false;
			Item &item=items[i];
			if (item.category!=category) continue;
			auto key=std::make_pair(std::wstring(item.Name()),item.bMetroLink);
			auto inserted=groups.emplace(std::move(key),NameGroup{i,{}});
			if (inserted.second)
				item.duplicateGroup=nextGroup++;
			else
			{
				NameGroup &group=inserted.first->second;
				if (group.appIds.empty())
					group.appIds.emplace(resolve(items[group.first]),items[group.first].duplicateGroup);
				if (cancelled()) return false;
				auto app=group.appIds.emplace(resolve(item),nextGroup);
				if (app.second) nextGroup++;
				item.duplicateGroup=app.first->second;
			}
		}
		return !cancelled();
	}

	template<class Item, class Match, class Emit>
	void SelectPrograms( const std::vector<Item> &items, int category, Match match, Emit emit )
	{
		std::vector<unsigned char> seen(items.size(),0);
		for (const Item &item:items)
		{
			// Filter before deduplication: links with the same name/AppID can
			// have different keywords, so a non-matching link must not hide a hit.
			if (item.category!=category || !match(item)) continue;
			if (seen[item.duplicateGroup]) continue;
			seen[item.duplicateGroup]=1;
			emit(item);
		}
	}

	template<class Item, class Match, class Emit>
	void SelectSettings( const std::vector<Item> &items, int category, int metroCategory, Match match, Emit emit )
	{
		struct Hit { const Item *item; int rank; };
		std::vector<Hit> hits;
		for (const Item &item:items)
		{
			if (item.category!=category && item.category!=metroCategory) continue;
			int matched=match(item);
			if (matched) hits.push_back({&item,(item.rank&~1)|(matched>>1)});
		}
		std::sort(hits.begin(),hits.end(),[](const Hit &a,const Hit &b)
		{
			return a.rank>b.rank || (a.rank==b.rank && wcscmp(a.item->Name(),b.item->Name())<0);
		});
		for (const Hit &hit:hits) emit(*hit.item);
	}
}
