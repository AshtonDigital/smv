#include "options.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include GLUT_H

#include "smokeviewvars.h"
#include "smokeviewdefs.h"
#include "glui_bounds.h"
#include "glui_motion.h"

#define NRESULT_WORKFLOWS 4
#define WORKFLOW_LABEL_LEN 256

enum workflow_type {
  WORKFLOW_VISIBILITY = 0,
  WORKFLOW_TEMPERATURE,
  WORKFLOW_VELOCITY,
  WORKFLOW_PRESSURE
};

typedef struct {
  const char *name;
  char slice_label[WORKFLOW_LABEL_LEN];
  char colorbar_label[WORKFLOW_LABEL_LEN];
  int configured;
  int next_plane;
} result_workflow;

typedef struct {
  int group_index;
  int is_vector;
  int idir;
  float position;
} workflow_plane;

static result_workflow workflows[NRESULT_WORKFLOWS] = {
  {"visibility",  "VIS_C0.9H0.1", "Visibility",  1, 0},
  {"temperature", "temp",          "Temperature", 1, 0},
  {"velocity",    "vel",           "Velocity",    1, 0},
  {"pressure",    "pres",          "Pressure",    1, 0}
};

static const char *default_slice_labels[NRESULT_WORKFLOWS] = {
  "VIS_C0.9H0.1", "temp", "vel", "pres"
};

static const char *default_colorbar_labels[NRESULT_WORKFLOWS] = {
  "Visibility", "Temperature", "Velocity", "Pressure"
};

static int active_workflow = -1;
static workflow_plane active_plane = {-1, 0, 0, 0.0f};
static int workflow_camera_clip_saved = 0;
static cameradata workflow_camera_saved;
static clipdata workflow_clip_saved;
static int workflow_clip_mode_saved = CLIP_OFF;
static int last_view_axis = -1;
static int next_view_stage = 0;

static void HideWorkflowPlane(const workflow_plane *plane);
static void RestoreWorkflowCameraClip(void);

/* ------------------ ResetResultWorkflows ------------------------ */

void ResetResultWorkflows(void){
  int i;

  HideWorkflowPlane(&active_plane);
  RestoreWorkflowCameraClip();
  for(i = 0; i < NRESULT_WORKFLOWS; i++){
    strcpy(workflows[i].slice_label, default_slice_labels[i]);
    strcpy(workflows[i].colorbar_label, default_colorbar_labels[i]);
    workflows[i].configured = 1;
    workflows[i].next_plane = 0;
  }
  active_workflow = -1;
  active_plane.group_index = -1;
  workflow_camera_clip_saved = 0;
  last_view_axis = -1;
  next_view_stage = 0;
}

/* ------------------ GetWorkflowIndex ------------------------ */

static int GetWorkflowIndex(const char *name){
  int i;

  for(i = 0; i < NRESULT_WORKFLOWS; i++){
    if(STRCMP(name, workflows[i].name) == 0)return i;
  }
  return -1;
}

/* ------------------ ConfigureResultWorkflow ------------------------ */

void ConfigureResultWorkflow(const char *name, const char *slice_label, const char *workflow_colorbar_label){
  int index;

  if(name == NULL || slice_label == NULL || workflow_colorbar_label == NULL)return;
  index = GetWorkflowIndex(name);
  if(index < 0){
    fprintf(stderr, "*** Warning: unknown RESULTWORKFLOW name: %s\n", name);
    return;
  }
  if(slice_label[0] == 0 || workflow_colorbar_label[0] == 0){
    fprintf(stderr, "*** Warning: RESULTWORKFLOW %s requires a slice and colorbar label\n", name);
    return;
  }
  strncpy(workflows[index].slice_label, slice_label, WORKFLOW_LABEL_LEN - 1);
  workflows[index].slice_label[WORKFLOW_LABEL_LEN - 1] = 0;
  strncpy(workflows[index].colorbar_label, workflow_colorbar_label, WORKFLOW_LABEL_LEN - 1);
  workflows[index].colorbar_label[WORKFLOW_LABEL_LEN - 1] = 0;
  workflows[index].configured = 1;
  workflows[index].next_plane = 0;
}

/* ------------------ SliceLabelMatches ------------------------ */

static int SliceLabelMatches(const slicedata *slicei, const char *label){
  if(slicei == NULL || label == NULL)return 0;
  if(STRCMP(slicei->label.shortlabel, label) == 0)return 1;
  if(STRCMP(slicei->label.longlabel, label) == 0)return 1;
  return 0;
}

/* ------------------ CompareWorkflowPlanes ------------------------ */

static int CompareWorkflowPlanes(const void *arg1, const void *arg2){
  const workflow_plane *plane1 = (const workflow_plane *)arg1;
  const workflow_plane *plane2 = (const workflow_plane *)arg2;

  if(plane1->idir != plane2->idir)return plane1->idir - plane2->idir;
  if(plane1->position < plane2->position)return -1;
  if(plane1->position > plane2->position)return 1;
  return plane1->group_index - plane2->group_index;
}

/* ------------------ BuildWorkflowPlanes ------------------------ */

static int BuildWorkflowPlanes(const result_workflow *workflow, int is_vector, workflow_plane **planes_ptr){
  workflow_plane *planes;
  int count = 0, i, capacity;

  capacity = is_vector == 1 ? global_scase.slicecoll.nmultivsliceinfo : global_scase.slicecoll.nmultisliceinfo;
  *planes_ptr = NULL;
  if(capacity <= 0)return 0;
  if(NewMemory((void **)&planes, (size_t)capacity * sizeof(workflow_plane)) == 0)return 0;

  for(i = 0; i < capacity; i++){
    slicedata *slicei = NULL;

    if(is_vector == 1){
      multivslicedata *mvslicei = global_scase.slicecoll.multivsliceinfo + i;
      vslicedata *vslicei;

      if(mvslicei->nvslices <= 0)continue;
      vslicei = global_scase.slicecoll.vsliceinfo + mvslicei->ivslices[0];
      if(vslicei->ival < 0)continue;
      slicei = global_scase.slicecoll.sliceinfo + vslicei->ival;
    }
    else{
      multislicedata *mslicei = global_scase.slicecoll.multisliceinfo + i;

      if(mslicei->nslices <= 0)continue;
      slicei = global_scase.slicecoll.sliceinfo + mslicei->islices[0];
    }
    if(slicei->slice3d == 1 || slicei->idir < 1 || slicei->idir > 3)continue;
    if(SliceLabelMatches(slicei, workflow->slice_label) == 0)continue;

    planes[count].group_index = i;
    planes[count].is_vector = is_vector;
    planes[count].idir = slicei->idir;
    planes[count].position = slicei->position_orig;
    count++;
  }
  if(count == 0){
    FREEMEMORY(planes);
    return 0;
  }
  qsort(planes, (size_t)count, sizeof(workflow_plane), CompareWorkflowPlanes);
  *planes_ptr = planes;
  return count;
}

/* ------------------ HideWorkflowPlane ------------------------ */

static void HideWorkflowPlane(const workflow_plane *plane){
  int i;

  if(plane == NULL || plane->group_index < 0)return;
  if(plane->is_vector == 1){
    multivslicedata *mvslicei = global_scase.slicecoll.multivsliceinfo + plane->group_index;
    for(i = 0; i < mvslicei->nvslices; i++){
      vslicedata *vslicei = global_scase.slicecoll.vsliceinfo + mvslicei->ivslices[i];
      vslicei->display = 0;
    }
  }
  else{
    multislicedata *mslicei = global_scase.slicecoll.multisliceinfo + plane->group_index;
    for(i = 0; i < mslicei->nslices; i++){
      slicedata *slicei = global_scase.slicecoll.sliceinfo + mslicei->islices[i];
      slicei->display = 0;
    }
  }
  updatemenu = 1;
  GLUTPOSTREDISPLAY;
}

/* ------------------ LoadScalarWorkflowPlane ------------------------ */

static void LoadScalarWorkflowPlane(const workflow_plane *plane){
  multislicedata *mslicei = global_scase.slicecoll.multisliceinfo + plane->group_index;
  int last_unloaded = -1, i;

  for(i = mslicei->nslices - 1; i >= 0; i--){
    slicedata *slicei = global_scase.slicecoll.sliceinfo + mslicei->islices[i];
    if(slicei->skipdup == 0 && slicei->loaded == 0){
      last_unloaded = mslicei->islices[i];
      break;
    }
  }
  for(i = 0; i < mslicei->nslices; i++){
    int slice_index = mslicei->islices[i];
    slicedata *slicei = global_scase.slicecoll.sliceinfo + slice_index;

    if(slicei->skipdup == 1)continue;
    if(slicei->loaded == 0){
      int color_flag = slice_index == last_unloaded ? SET_SLICECOLOR : DEFER_SLICECOLOR;
      slicei->finalize = slice_index == last_unloaded;
      LoadSlicei(color_flag, slice_index, ALL_FRAMES, NULL);
    }
    slicei->display = 1;
  }
  SetLoadedSliceBounds(mslicei->islices, mslicei->nslices);
}

/* ------------------ LoadVectorWorkflowPlane ------------------------ */

static void LoadVectorWorkflowPlane(const workflow_plane *plane){
  multivslicedata *mvslicei = global_scase.slicecoll.multivsliceinfo + plane->group_index;
  int *slice_list = NULL;
  int nslices = 0, i;

  if(mvslicei->nvslices > 0)NewMemory((void **)&slice_list, (size_t)mvslicei->nvslices * sizeof(int));
  for(i = 0; i < mvslicei->nvslices; i++){
    int vslice_index = mvslicei->ivslices[i];
    vslicedata *vslicei = global_scase.slicecoll.vsliceinfo + vslice_index;

    if(vslicei->skip == 1)continue;
    if(vslicei->loaded == 0)LoadVSliceMenu2(vslice_index);
    vslicei->display = 1;
    if(slice_list != NULL && vslicei->ival >= 0)slice_list[nslices++] = vslicei->ival;
  }
  if(nslices > 0)SetLoadedSliceBounds(slice_list, nslices);
  FREEMEMORY(slice_list);
}

/* ------------------ ApplyWorkflowColorbar ------------------------ */

static void ApplyWorkflowColorbar(const result_workflow *workflow){
  colorbardata *colorbar;

  colorbar = GetColorbar(&colorbars, workflow->colorbar_label);
  if(colorbar == NULL){
    fprintf(stderr, "*** Warning: workflow %s colorbar not found: %s\n", workflow->name, workflow->colorbar_label);
    return;
  }
  ColorbarMenu((int)(colorbar - colorbars.colorbarinfo));
}

/* ------------------ ApplyWorkflowBounds ------------------------ */

static void ApplyWorkflowBounds(const result_workflow *workflow, const workflow_plane *plane){
  float valmin = 1.0f, valmax = 0.0f, configured_min = 0.0f, configured_max = 0.0f;
  int set_valmin = BOUND_LOADED_MIN, set_valmax = BOUND_LOADED_MAX;
  const char *bounds_label = workflow->slice_label;
  int i;

  if(plane->is_vector == 1){
    multivslicedata *mvslicei = global_scase.slicecoll.multivsliceinfo + plane->group_index;
    if(mvslicei->nvslices > 0){
      vslicedata *vslicei = global_scase.slicecoll.vsliceinfo + mvslicei->ivslices[0];
      if(vslicei->ival >= 0)bounds_label = global_scase.slicecoll.sliceinfo[vslicei->ival].label.shortlabel;
    }
  }
  else{
    multislicedata *mslicei = global_scase.slicecoll.multisliceinfo + plane->group_index;
    if(mslicei->nslices > 0)bounds_label = global_scase.slicecoll.sliceinfo[mslicei->islices[0]].label.shortlabel;
  }

  GLUIGetMinMax(BOUND_SLICE, (char *)bounds_label,
                &set_valmin, &configured_min, &set_valmax, &configured_max);
  if(set_valmin == BOUND_SET_MIN && set_valmax == BOUND_SET_MAX)return;

  if(plane->is_vector == 1){
    multivslicedata *mvslicei = global_scase.slicecoll.multivsliceinfo + plane->group_index;

    for(i = 0; i < mvslicei->nvslices; i++){
      vslicedata *vslicei = global_scase.slicecoll.vsliceinfo + mvslicei->ivslices[i];
      slicedata *slicei;

      if(vslicei->ival < 0)continue;
      slicei = global_scase.slicecoll.sliceinfo + vslicei->ival;
      if(valmin > valmax){
        valmin = slicei->valmin_slice;
        valmax = slicei->valmax_slice;
      }
      else{
        valmin = MIN(valmin, slicei->valmin_slice);
        valmax = MAX(valmax, slicei->valmax_slice);
      }
    }
  }
  else{
    multislicedata *mslicei = global_scase.slicecoll.multisliceinfo + plane->group_index;

    for(i = 0; i < mslicei->nslices; i++){
      slicedata *slicei = global_scase.slicecoll.sliceinfo + mslicei->islices[i];

      if(slicei->skipdup == 1)continue;
      if(valmin > valmax){
        valmin = slicei->valmin_slice;
        valmax = slicei->valmax_slice;
      }
      else{
        valmin = MIN(valmin, slicei->valmin_slice);
        valmax = MAX(valmax, slicei->valmax_slice);
      }
    }
  }
  if(valmin <= valmax){
    fprintf(stderr, "*** Warning: workflow %s has no fixed V2_SLICE bounds; using loaded bounds\n", workflow->name);
    SetSliceMin(BOUND_LOADED_MIN, valmin, (char *)bounds_label);
    SetSliceMax(BOUND_LOADED_MAX, valmax, (char *)bounds_label);
  }
}

/* ------------------ SaveWorkflowCameraClip ------------------------ */

static void SaveWorkflowCameraClip(void){
  if(workflow_camera_clip_saved == 1)return;
  memcpy(&workflow_camera_saved, camera_current, sizeof(cameradata));
  memcpy(&workflow_clip_saved, &clipinfo, sizeof(clipdata));
  workflow_clip_mode_saved = clip_mode;
  workflow_camera_clip_saved = 1;
}

/* ------------------ RestoreWorkflowCameraClip ------------------------ */

static void RestoreWorkflowCameraClip(void){
  if(workflow_camera_clip_saved == 0)return;
  memcpy(&clipinfo, &workflow_clip_saved, sizeof(clipdata));
  clip_mode = workflow_clip_mode_saved;
  CopyCamera(camera_current, &workflow_camera_saved);
  GLUIUpdateClip();
  updatefacelists = 1;
  global_scase.updatefaces = 1;
  workflow_camera_clip_saved = 0;
}

/* ------------------ SetFittedAxisView ------------------------ */

static void SetFittedAxisView(int view){
  SetCameraView(camera_current, view);
  camera_current->zoom = 1.0f;
  zoom = 1.0f;
  zoomindex = ZOOMINDEX_ONE;
  GLUIUpdateZoom();
}

/* ------------------ ApplyWorkflowClipView ------------------------ */

static void ApplyWorkflowClipView(const workflow_plane *plane){
  int view;
  int *clip_enabled;
  float *clip_value;

  SaveWorkflowCameraClip();
  switch(plane->idir){
    case 1:
      clip_enabled = &clipinfo.clip_xmax;
      clip_value = &clipinfo.xmax;
      view = MENU_VIEW_XMAX;
      break;
    case 2:
      clip_enabled = &clipinfo.clip_ymax;
      clip_value = &clipinfo.ymax;
      view = MENU_VIEW_YMAX;
      break;
    case 3:
      clip_enabled = &clipinfo.clip_zmax;
      clip_value = &clipinfo.zmax;
      view = MENU_VIEW_ZMAX;
      break;
    default:
      return;
  }

  // Orthographic view changes restore the exterior camera, including its clip state.
  SetFittedAxisView(view);
  clipinfo.clip_xmin = 0;
  clipinfo.clip_xmax = 0;
  clipinfo.clip_ymin = 0;
  clipinfo.clip_ymax = 0;
  clipinfo.clip_zmin = 0;
  clipinfo.clip_zmax = 0;
  clip_mode = CLIP_BLOCKAGES_DATA;
  *clip_enabled = 1;
  *clip_value = plane->position;
  Clip2Cam(camera_current);
  GLUIUpdateClip();
  PRINTF("Review clipping: %c <= %.3f\n", 'X' + plane->idir - 1, plane->position);
  updatefacelists = 1;
  global_scase.updatefaces = 1;
  GLUTPOSTREDISPLAY;
}

/* ------------------ SelectWorkflowPlane ------------------------ */

static void SelectWorkflowPlane(int workflow_index, int apply_clip_view){
  result_workflow *workflow = workflows + workflow_index;
  workflow_plane *planes = NULL;
  int is_vector = 0;
  int nplanes;

  if(workflow->configured == 0){
    fprintf(stderr, "*** Warning: RESULTWORKFLOW %s is not configured\n", workflow->name);
    return;
  }
  nplanes = BuildWorkflowPlanes(workflow, is_vector, &planes);
  if(nplanes == 0){
    fprintf(stderr, "*** Warning: no %s slices match label %s\n", workflow->name, workflow->slice_label);
    return;
  }

  HideWorkflowPlane(&active_plane);
  if(apply_clip_view == 0)RestoreWorkflowCameraClip();
  if(active_workflow != workflow_index)workflow->next_plane = 0;

  if(workflow->next_plane >= nplanes){
    workflow->next_plane = 0;
    active_workflow = -1;
    active_plane.group_index = -1;
    RestoreWorkflowCameraClip();
    PRINTF("Review workflow %s: off\n", workflow->name);
    FREEMEMORY(planes);
    return;
  }

  active_plane = planes[workflow->next_plane];
  active_workflow = workflow_index;
  workflow->next_plane++;
  PRINTF("Review workflow %s: %c slice at %.3f (%i of %i)\n",
         workflow->name, 'X' + active_plane.idir - 1, active_plane.position,
         workflow->next_plane, nplanes);
  if(active_plane.is_vector == 1)LoadVectorWorkflowPlane(&active_plane);
  else LoadScalarWorkflowPlane(&active_plane);
  ApplyWorkflowColorbar(workflow);
  ApplyWorkflowBounds(workflow, &active_plane);
  UpdateSliceBounds2();
  UpdateRGBColors(colorbar_select_index);
  if(apply_clip_view == 1)ApplyWorkflowClipView(&active_plane);
  GLUTPOSTREDISPLAY;
  FREEMEMORY(planes);
}

/* ------------------ CycleAxisView ------------------------ */

static void CycleAxisView(int axis){
  static const int views[3][2] = {
    {MENU_VIEW_XMIN, MENU_VIEW_XMAX},
    {MENU_VIEW_YMIN, MENU_VIEW_YMAX},
    {MENU_VIEW_ZMIN, MENU_VIEW_ZMAX}
  };

  RestoreWorkflowCameraClip();
  if(last_view_axis != axis){
    last_view_axis = axis;
    next_view_stage = 0;
  }
  if(next_view_stage < 2)SetFittedAxisView(views[axis][next_view_stage]);
  else SetViewPoint(RESTORE_EXTERIOR_VIEW);
  next_view_stage = (next_view_stage + 1) % 3;
  GLUTPOSTREDISPLAY;
}

/* ------------------ HandleResultWorkflowShortcut ------------------------ */

int HandleResultWorkflowShortcut(unsigned char key, int modifiers){
  int apply_clip_view;
  unsigned char lower_key;

  if((modifiers & GLUT_ACTIVE_CTRL) == 0 || (modifiers & GLUT_ACTIVE_ALT) != 0)return 0;
  lower_key = key;
  if(lower_key >= 1 && lower_key <= 26)lower_key = (unsigned char)('a' + lower_key - 1);
  if(lower_key >= 'A' && lower_key <= 'Z')lower_key = (unsigned char)(lower_key - 'A' + 'a');
  apply_clip_view = 1;

  switch(lower_key){
    case 'x':
      if((modifiers & GLUT_ACTIVE_SHIFT) != 0)return 0;
      CycleAxisView(0);
      return 1;
    case 'y':
      if((modifiers & GLUT_ACTIVE_SHIFT) != 0)return 0;
      CycleAxisView(1);
      return 1;
    case 'z':
      if((modifiers & GLUT_ACTIVE_SHIFT) != 0)return 0;
      CycleAxisView(2);
      return 1;
    case 'i':
      SelectWorkflowPlane(WORKFLOW_VISIBILITY, apply_clip_view);
      return 1;
    case 't':
      SelectWorkflowPlane(WORKFLOW_TEMPERATURE, apply_clip_view);
      return 1;
    case 'v':
      SelectWorkflowPlane(WORKFLOW_VELOCITY, apply_clip_view);
      return 1;
    case 'p':
      SelectWorkflowPlane(WORKFLOW_PRESSURE, apply_clip_view);
      return 1;
    default:
      return 0;
  }
}
