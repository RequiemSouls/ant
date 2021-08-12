#include "../Include/RmlUi/Texture.h"
#include "../Include/RmlUi/RenderInterface.h"
#include "../Include/RmlUi/Core.h"
#include "../Include/RmlUi/Log.h"

namespace Rml {

Texture::Texture(const std::string& _source)
	: source(_source) {
	if (!GetRenderInterface()->LoadTexture(handle, dimensions, source)) {
		Log::Message(Log::Level::Warning, "Failed to load texture from %s.", source.c_str());
		handle = 0;
		dimensions = Size(0, 0);
	}
}

Texture::~Texture() {
	if (handle && GetRenderInterface()) {
		GetRenderInterface()->ReleaseTexture(handle);
		handle = 0;
	}
}

TextureHandle Texture::GetHandle() const {
	return handle;
}

const Size& Texture::GetDimensions() const {
	return dimensions;
}

using TextureMap = std::unordered_map<std::string, std::shared_ptr<Texture>>;
static TextureMap textures;

void Texture::Shutdown() {
#ifdef RMLUI_DEBUG
	// All textures not owned by the database should have been released at this point.
	int num_leaks_file = 0;
	for (auto& texture : textures) {
		num_leaks_file += (texture.second.use_count() > 1);
	}
	if (num_leaks_file > 0) {
		Log::Message(Log::Level::Error, "Textures leaked during shutdown. Total: %d.", num_leaks_file);
	}
#endif
	textures.clear();
}

std::shared_ptr<Texture> Texture::Fetch(const std::string& path) {
	auto iterator = textures.find(path);
	if (iterator != textures.end()) {
		return iterator->second;
	}
	auto resource = std::make_shared<Texture>(path);
	textures[path] = resource;
	return resource;
}

} // namespace Rml
