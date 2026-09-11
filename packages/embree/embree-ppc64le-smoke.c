/* Omarchy ppc64le: end-to-end runtime check for the VSX-backed embree.
   One triangle at z=5; a ray down +z must hit it at t=5, a ray offset to
   x=3 must miss, and a 4-wide packet must agree lane by lane. */
#include <embree4/rtcore.h>
#include <stdio.h>
#include <math.h>
int main(void) {
  RTCDevice dev = rtcNewDevice("verbose=1");
  if (!dev) { printf("no device\n"); return 2; }
  RTCScene scene = rtcNewScene(dev);
  RTCGeometry g = rtcNewGeometry(dev, RTC_GEOMETRY_TYPE_TRIANGLE);
  float* v = rtcSetNewGeometryBuffer(g, RTC_BUFFER_TYPE_VERTEX, 0, RTC_FORMAT_FLOAT3, 3*sizeof(float), 3);
  unsigned* idx = rtcSetNewGeometryBuffer(g, RTC_BUFFER_TYPE_INDEX, 0, RTC_FORMAT_UINT3, 3*sizeof(unsigned), 1);
  v[0]=-1;v[1]=-1;v[2]=5;  v[3]=1;v[4]=-1;v[5]=5;  v[6]=0;v[7]=1;v[8]=5;
  idx[0]=0;idx[1]=1;idx[2]=2;
  rtcCommitGeometry(g); rtcAttachGeometry(scene, g); rtcReleaseGeometry(g);
  rtcCommitScene(scene);
  int fails = 0;
  struct RTCRayHit rh = {0};
  rh.ray.dir_z=1; rh.ray.tfar=INFINITY; rh.ray.mask=-1; rh.hit.geomID=RTC_INVALID_GEOMETRY_ID;
  rtcIntersect1(scene, &rh, NULL);
  printf("ray1 geomID=%u tfar=%f u=%f v=%f\n", rh.hit.geomID, rh.ray.tfar, rh.hit.u, rh.hit.v);
  if (rh.hit.geomID != 0 || fabsf(rh.ray.tfar-5.0f) > 1e-4f) fails++;
  struct RTCRayHit rm = {0};
  rm.ray.org_x=3; rm.ray.dir_z=1; rm.ray.tfar=INFINITY; rm.ray.mask=-1; rm.hit.geomID=RTC_INVALID_GEOMETRY_ID;
  rtcIntersect1(scene, &rm, NULL);
  printf("ray2 geomID=%u (expect miss)\n", rm.hit.geomID);
  if (rm.hit.geomID != RTC_INVALID_GEOMETRY_ID) fails++;
  struct RTCRayHit4 r4; int valid[4]={-1,-1,-1,-1};
  for (int i=0;i<4;i++){ r4.ray.org_x[i]=(i==3)?3.f:0.f; r4.ray.org_y[i]=0; r4.ray.org_z[i]=0; r4.ray.dir_x[i]=0; r4.ray.dir_y[i]=0; r4.ray.dir_z[i]=1; r4.ray.tnear[i]=0; r4.ray.tfar[i]=INFINITY; r4.ray.mask[i]=-1; r4.ray.flags[i]=0; r4.ray.time[i]=0; r4.hit.geomID[i]=RTC_INVALID_GEOMETRY_ID; }
  rtcIntersect4(valid, scene, &r4, NULL);
  for (int i=0;i<4;i++) printf("pkt[%d] geomID=%u tfar=%f\n", i, r4.hit.geomID[i], r4.ray.tfar[i]);
  for (int i=0;i<3;i++) if (r4.hit.geomID[i]!=0 || fabsf(r4.ray.tfar[i]-5.0f)>1e-4f) fails++;
  if (r4.hit.geomID[3]!=RTC_INVALID_GEOMETRY_ID) fails++;
  rtcReleaseScene(scene); rtcReleaseDevice(dev);
  printf(fails ? "EMBREE-RUNTIME-FAIL (%d)\n" : "EMBREE-RUNTIME-OK\n", fails);
  return fails;
}
