#pragma once

#include <binding/luabind.h>
#include <core/Interface.h>
#include "luaref.h"

namespace Rml {
class Node;
class Element;
class Document;
class Event;
}

enum class LuaEvent : uint8_t {
	OnCreateElement = 2,
	OnCreateText,
	OnDispatchEvent,
	OnDestroyNode,
	OnLoadTexture,
	OnParseText,
};

class lua_plugin final : public Rml::Plugin {
public:
	lua_plugin(lua_State* L);
	~lua_plugin();
	void OnCreateElement(Rml::Document* document, Rml::Element* element, const std::string& tag) override;
	void OnCreateText(Rml::Document* document, Rml::Text* text) override;
	void OnDispatchEvent(Rml::Document* document, Rml::Element* element, const std::string& type, const luavalue::table& eventData) override;
	void OnDestroyNode(Rml::Document* document, Rml::Node* node) override;
	void OnLoadTexture(Rml::Document* document, Rml::Element* element, const std::string& path) override;
	void OnLoadTexture(Rml::Document* document, Rml::Element* element, const std::string& path, Rml::Size size) override;
	void OnParseText(const std::string& str,std::vector<Rml::group>& groups,std::vector<int>& groupMap,std::vector<Rml::image>& images,std::vector<int>& imageMap,std::string& ctext,Rml::group& default_group) override;

	void register_event(lua_State* L);
	luaref_box ref(lua_State* L);
	void callref(lua_State* L, int ref, size_t argn = 0, size_t retn = 0);
	void call(lua_State* L, LuaEvent eid, size_t argn = 0, size_t retn = 0);
	void pushevent(lua_State* L, const Rml::Event& event);

	luaref reference = 0;
};

lua_plugin* get_lua_plugin();
