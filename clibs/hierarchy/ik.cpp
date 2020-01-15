#include "hierarchy.h"

extern "C" {
#define LUA_LIB
#include "lua.h"
#include "lauxlib.h"
}

#include <ozz/animation/runtime/skeleton.h>
#include <ozz/animation/runtime/animation.h>
#include <ozz/animation/runtime/sampling_job.h>
#include <ozz/animation/runtime/local_to_model_job.h>
#include <ozz/animation/runtime/skeleton.h>

#include <ozz/animation/runtime/ik_two_bone_job.h>
#include <ozz/animation/runtime/ik_aim_job.h>

#include <ozz/base/maths/simd_math.h>
#include <ozz/base/maths/simd_quaternion.h>
#include <ozz/base/maths/soa_transform.h>

#include <ozz/base/containers/vector.h>

static ozz::math::Float4x4
to_matrix(lua_State *L, int idx) {
	ozz::math::Float4x4 sf;
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
	const float* m = (const float*)lua_touserdata(L, idx);	
	float* p = reinterpret_cast<float*>(&sf);
	for (int ii = 0; ii < 16; ++ii) {
		*p++ = m[ii];
	}

	return sf;
}

bool
do_ltm(ozz::animation::Skeleton *ske,
	const ozz::Vector<ozz::math::SoaTransform>::Std &intermediateResult,
	ozz::Vector<ozz::math::Float4x4>::Std &joints,
	const ozz::math::Float4x4 *root = nullptr,
	int from = ozz::animation::Skeleton::kNoParent,
	int to = ozz::animation::Skeleton::kMaxJoints);

#ifdef _DEBUG
#define verfiy(_c, _check)	assert((_c) == _check)
#else
#define verfiy(_c, _check)	(_c)
#endif // _DEBUG


static void 
prepare_two_bone_ik_job(lua_State *L, int idx, 
	const ozz::Range<ozz::math::Float4x4> &models, 
	ozz::animation::IKTwoBoneJob &job) {
	luaL_checktype(L, idx, LUA_TTABLE);

	auto get_vec = [L](int idx, auto name, auto *result) {
		verfiy(lua_getfield(L, idx, name), LUA_TLIGHTUSERDATA);
		auto p = (const float*)lua_touserdata(L, -1);
		for (int ii = 0; ii < 4; ++ii) {
			*result++ = p[ii];
		}

		lua_pop(L, 1);
	};

	// define in model space
	get_vec(idx, "target", (float*)(&job.target));
	get_vec(idx, "pole_vector", (float*)(&job.pole_vector));
	get_vec(idx, "mid_axis", (float*)(&job.mid_axis));

	auto get_number = [L](int idx, auto name) {
		verfiy(lua_getfield(L, idx, name), LUA_TNUMBER);
		const float value = (float)lua_tonumber(L, -1);
		lua_pop(L, 1);

		return value;
	};
	
	job.weight = get_number(idx, "weight");
	job.soften = get_number(idx, "soften");
	job.twist_angle = get_number(idx, "twist_angle");
	
	auto get_joint = [L, &models](int idx, auto name)->ozz::math::Float4x4* {
		verfiy(lua_getfield(L, idx, name), LUA_TNUMBER);
		const size_t jointidx = (size_t)lua_tointeger(L, -1) - 1;
		lua_pop(L, 1);

		if (0 < jointidx && jointidx < models.count()) {
			return &models[jointidx];
		}

		luaL_error(L, "joint idx out of range:%d", jointidx);
		return nullptr;
	};

	job.start_joint = get_joint(idx, "start_joint");
	job.mid_joint = get_joint(idx, "mid_joint");
	job.end_joint = get_joint(idx, "end_joint");
}

static inline void 
mul_quaternion(size_t jointidx, const ozz::math::SimdQuaternion& quat,
	ozz::Vector<ozz::math::SoaTransform>::Std& transforms) {	

	ozz::math::SoaTransform& soa_transform_ref = transforms[jointidx / 4];
	ozz::math::SimdQuaternion aos_quats[4];
	ozz::math::Transpose4x4(&soa_transform_ref.rotation.x, &aos_quats->xyzw);

	ozz::math::SimdQuaternion& aos_joint_quat_ref = aos_quats[jointidx & 3];
	aos_joint_quat_ref = aos_joint_quat_ref * quat;

	ozz::math::Transpose4x4(&aos_quats->xyzw, &soa_transform_ref.rotation.x);
}

auto get_ske(lua_State *L, int index = 1){
	luaL_checktype(L, 1, LUA_TUSERDATA);
	hierarchy_build_data *builddata = (hierarchy_build_data *)lua_touserdata(L, 1);
	auto ske = builddata->skeleton;
	if (ske == nullptr) {
		luaL_error(L, "skeleton data must init!");
		return (ozz::animation::Skeleton*)nullptr;
	}

	return ske;
}

static int
ldo_two_bone_ik(lua_State *L) {	
	auto ske = get_ske(L, 1);

	luaL_checkudata(L, 2, "OZZ_BIND_POSE");
	bind_pose* result = (bind_pose*)lua_touserdata(L, 2);

	const bool fixroot = lua_isnoneornil(L, 3) ? false : lua_toboolean(L, 3);

	const auto &poses = ske->joint_bind_poses();
	ozz::Vector<ozz::math::SoaTransform>::Std local_trans(poses.count());	
	for (size_t ii = 0; ii < poses.count(); ++ii)
		local_trans[ii] = poses[ii];

	ozz::animation::IKTwoBoneJob ikjob;
	auto jointrange = ozz::make_range(result->pose);
	prepare_two_bone_ik_job(L, 4, jointrange, ikjob);

	ozz::math::SimdQuaternion start_correction, mid_correction;
	ikjob.start_joint_correction = &start_correction;
	ikjob.mid_joint_correction = &mid_correction;

	if (!ikjob.Run()) {
		luaL_error(L, "run two bones ik failed");
	}

	const size_t start_jointidx = ikjob.start_joint - jointrange.begin;
	mul_quaternion(start_jointidx, start_correction, local_trans);
	const size_t mid_jointidx = ikjob.mid_joint - jointrange.begin;
	mul_quaternion(mid_jointidx, mid_correction, local_trans);

	if (!do_ltm(ske, local_trans, result->pose, nullptr, (int)start_jointidx)) {
		luaL_error(L, "rerun local to model job after ik failed");
	}
	return 0;
}

static int
ldo_aim_ik(lua_State *L){
	auto ske = get_ske(L, 1);

	
	return 0;
}

extern "C" {
	LUAMOD_API int
	luaopen_hierarchy_ik(lua_State *L) {
		luaL_Reg l[] = {
			{ "do_two_bone_ik", ldo_two_bone_ik},
			{ "do_aim_ik", ldo_aim_ik},
			{nullptr, nullptr},
		};

		luaL_newlib(L, l);
		return 1;
	}
}