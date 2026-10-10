#include <metal_stdlib>
using namespace metal;

struct ShaderUniforms {
    float4 resolutionTime; // width, height, seconds, unused
    float4 mouse;          // Shadertoy mouse pixel coordinates
};

// Adapted from the user-supplied MIT-licensed shader by Inigo Quilez.
// The complete copyright and license notice follows.
// The MIT License
// Copyright © 2013 Inigo Quilez
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

// A list of useful distance function to simple primitives. All
// these functions (except for ellipsoid) return an exact
// euclidean distance, meaning they produce a better SDF than
// what you'd get if you were constructing them from boolean
// operations (such as cutting an infinite cylinder with two planes).

// List of other 3D SDFs:
//    https://www.shadertoy.com/playlist/43cXRl
// and
//    https://iquilezles.org/articles/distfunctions

#define AA 1 // Keep interactive pipeline frames bounded.

//------------------------------------------------------------------
float dot2( float2 v ) { return dot(v,v); }
float dot2( float3 v ) { return dot(v,v); }
float ndot( float2 a, float2 b ) { return a.x*b.x - a.y*b.y; }

float sdPlane( float3 p )
{
	return p.y;
}

float sdSphere( float3 p, float s )
{
    return length(p)-s;
}

float sdBox( float3 p, float3 b )
{
    float3 d = abs(p) - b;
    return min(max(d.x,max(d.y,d.z)),0.0) + length(max(d,0.0));
}

float sdBoxFrame( float3 p, float3 b, float e )
{
       p = abs(p  )-b;
  float3 q = abs(p+e)-e;

  return min(min(
      length(max(float3(p.x,q.y,q.z),0.0))+min(max(p.x,max(q.y,q.z)),0.0),
      length(max(float3(q.x,p.y,q.z),0.0))+min(max(q.x,max(p.y,q.z)),0.0)),
      length(max(float3(q.x,q.y,p.z),0.0))+min(max(q.x,max(q.y,p.z)),0.0));
}
float sdEllipsoid( float3 p, float3 r ) // approximated
{
    float k0 = length(p/r);
    float k1 = length(p/(r*r));
    return k0*(k0-1.0)/k1;
}

float sdTorus( float3 p, float2 t )
{
    return length( float2(length(p.xz)-t.x,p.y) )-t.y;
}

float sdCappedTorus(float3 p, float2 sc, float ra, float rb)
{
    p.x = abs(p.x);
    float k = (sc.y*p.x>sc.x*p.y) ? dot(p.xy,sc) : length(p.xy);
    return sqrt( dot(p,p) + ra*ra - 2.0*ra*k ) - rb;
}

float sdHexPrism( float3 p, float2 h )
{
    float3 q = abs(p);

    const float3 k = float3(-0.8660254, 0.5, 0.57735);
    p = abs(p);
    p.xy -= 2.0*min(dot(k.xy, p.xy), 0.0)*k.xy;
    float2 d = float2(
       length(p.xy - float2(clamp(p.x, -k.z*h.x, k.z*h.x), h.x))*sign(p.y - h.x),
       p.z-h.y );
    return min(max(d.x,d.y),0.0) + length(max(d,0.0));
}

float sdOctogonPrism( float3 p, float r, float h )
{
  const float3 k = float3(-0.9238795325,   // sqrt(2+sqrt(2))/2 
                       0.3826834323,   // sqrt(2-sqrt(2))/2
                       0.4142135623 ); // sqrt(2)-1 
  // reflections
  p = abs(p);
  p.xy -= 2.0*min(dot(float2( k.x,k.y),p.xy),0.0)*float2( k.x,k.y);
  p.xy -= 2.0*min(dot(float2(-k.x,k.y),p.xy),0.0)*float2(-k.x,k.y);
  // polygon side
  p.xy -= float2(clamp(p.x, -k.z*r, k.z*r), r);
  float2 d = float2( length(p.xy)*sign(p.y), p.z-h );
  return min(max(d.x,d.y),0.0) + length(max(d,0.0));
}

float sdCapsule( float3 p, float3 a, float3 b, float r )
{
	float3 pa = p-a, ba = b-a;
	float h = clamp( dot(pa,ba)/dot(ba,ba), 0.0, 1.0 );
	return length( pa - ba*h ) - r;
}

float sdRoundCone( float3 p, float r1, float r2, float h )
{
    float2 q = float2( length(p.xz), p.y );
    
    float b = (r1-r2)/h;
    float a = sqrt(1.0-b*b);
    float k = dot(q,float2(-b,a));
    
    if( k < 0.0 ) return length(q) - r1;
    if( k > a*h ) return length(q-float2(0.0,h)) - r2;
        
    return dot(q, float2(a,b) ) - r1;
}

float sdRoundCone(float3 p, float3 a, float3 b, float r1, float r2)
{
    // sampling independent computations (only depend on shape)
    float3  ba = b - a;
    float l2 = dot(ba,ba);
    float rr = r1 - r2;
    float a2 = l2 - rr*rr;
    float il2 = 1.0/l2;
    
    // sampling dependant computations
    float3 pa = p - a;
    float y = dot(pa,ba);
    float z = y - l2;
    float x2 = dot2( pa*l2 - ba*y );
    float y2 = y*y*l2;
    float z2 = z*z*l2;

    // single square root!
    float k = sign(rr)*rr*rr*x2;
    if( sign(z)*a2*z2 > k ) return  sqrt(x2 + z2)        *il2 - r2;
    if( sign(y)*a2*y2 < k ) return  sqrt(x2 + y2)        *il2 - r1;
                            return (sqrt(x2*a2*il2)+y*rr)*il2 - r1;
}

float sdTriPrism( float3 p, float2 h )
{
    const float k = sqrt(3.0);
    h.x *= 0.5*k;
    p.xy /= h.x;
    p.x = abs(p.x) - 1.0;
    p.y = p.y + 1.0/k;
    if( p.x+k*p.y>0.0 ) p.xy=float2(p.x-k*p.y,-k*p.x-p.y)/2.0;
    p.x -= clamp( p.x, -2.0, 0.0 );
    float d1 = length(p.xy)*sign(-p.y)*h.x;
    float d2 = abs(p.z)-h.y;
    return length(max(float2(d1,d2),0.0)) + min(max(d1,d2), 0.);
}

// vertical
float sdCylinder( float3 p, float2 h )
{
    float2 d = abs(float2(length(p.xz),p.y)) - h;
    return min(max(d.x,d.y),0.0) + length(max(d,0.0));
}

// arbitrary orientation
float sdCylinder(float3 p, float3 a, float3 b, float r)
{
    float3 pa = p - a;
    float3 ba = b - a;
    float baba = dot(ba,ba);
    float paba = dot(pa,ba);

    float x = length(pa*baba-ba*paba) - r*baba;
    float y = abs(paba-baba*0.5)-baba*0.5;
    float x2 = x*x;
    float y2 = y*y*baba;
    float d = (max(x,y)<0.0)?-min(x2,y2):(((x>0.0)?x2:0.0)+((y>0.0)?y2:0.0));
    return sign(d)*sqrt(abs(d))/baba;
}

// vertical
float sdCone( float3 p, float2 c, float h )
{
    float2 q = h*float2(c.x,-c.y)/c.y;
    float2 w = float2( length(p.xz), p.y );
    
	float2 a = w - q*clamp( dot(w,q)/dot(q,q), 0.0, 1.0 );
    float2 b = w - q*float2( clamp( w.x/q.x, 0.0, 1.0 ), 1.0 );
    float k = sign( q.y );
    float d = min(dot( a, a ),dot(b, b));
    float s = max( k*(w.x*q.y-w.y*q.x),k*(w.y-q.y)  );
	return sqrt(d)*sign(s);
}

float sdCappedCone( float3 p, float h, float r1, float r2 )
{
    float2 q = float2( length(p.xz), p.y );
    
    float2 k1 = float2(r2,h);
    float2 k2 = float2(r2-r1,2.0*h);
    float2 ca = float2(q.x-min(q.x,(q.y < 0.0)?r1:r2), abs(q.y)-h);
    float2 cb = q - k1 + k2*clamp( dot(k1-q,k2)/dot2(k2), 0.0, 1.0 );
    float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
    return s*sqrt( min(dot2(ca),dot2(cb)) );
}

float sdCappedCone(float3 p, float3 a, float3 b, float ra, float rb)
{
    float rba  = rb-ra;
    float baba = dot(b-a,b-a);
    float papa = dot(p-a,p-a);
    float paba = dot(p-a,b-a)/baba;

    float x = sqrt( papa - paba*paba*baba );

    float cax = max(0.0,x-((paba<0.5)?ra:rb));
    float cay = abs(paba-0.5)-0.5;

    float k = rba*rba + baba;
    float f = clamp( (rba*(x-ra)+paba*baba)/k, 0.0, 1.0 );

    float cbx = x-ra - f*rba;
    float cby = paba - f;
    
    float s = (cbx < 0.0 && cay < 0.0) ? -1.0 : 1.0;
    
    return s*sqrt( min(cax*cax + cay*cay*baba,
                       cbx*cbx + cby*cby*baba) );
}

// c is the sin/cos of the desired cone angle
float sdSolidAngle(float3 pos, float2 c, float ra)
{
    float2 p = float2( length(pos.xz), pos.y );
    float l = length(p) - ra;
	float m = length(p - c*clamp(dot(p,c),0.0,ra) );
    return max(l,m*sign(c.y*p.x-c.x*p.y));
}

float sdOctahedron(float3 p, float s)
{
    p = abs(p);
    float m = p.x + p.y + p.z - s;

    // exact distance
    #if 0
    float3 o = min(3.0*p - m, 0.0);
    o = max(6.0*p - m*2.0 - o*3.0 + (o.x+o.y+o.z), 0.0);
    return length(p - s*o/(o.x+o.y+o.z));
    #endif
    
    // exact distance
    #if 1
 	float3 q;
         if( 3.0*p.x < m ) q = p.xyz;
    else if( 3.0*p.y < m ) q = p.yzx;
    else if( 3.0*p.z < m ) q = p.zxy;
    else return m*0.57735027;
    float k = clamp(0.5*(q.z-q.y+s),0.0,s); 
    return length(float3(q.x,q.y-s+k,q.z-k)); 
    #endif
    
    // bound, not exact
    #if 0
	return m*0.57735027;
    #endif
}

float sdPyramid( float3 p, float h )
{
    float m2 = h*h + 0.25;
    
    // symmetry
    p.xz = abs(p.xz);
    p.xz = (p.z>p.x) ? p.zx : p.xz;
    p.xz -= 0.5;
	
    // project into face plane (2D)
    float3 q = float3( p.z, h*p.y - 0.5*p.x, h*p.x + 0.5*p.y);
   
    float s = max(-q.x,0.0);
    float t = clamp( (q.y-0.5*p.z)/(m2+0.25), 0.0, 1.0 );
    
    float a = m2*(q.x+s)*(q.x+s) + q.y*q.y;
	float b = m2*(q.x+0.5*t)*(q.x+0.5*t) + (q.y-m2*t)*(q.y-m2*t);
    
    float d2 = min(q.y,-q.x*m2-q.y*0.5) > 0.0 ? 0.0 : min(a,b);
    
    // recover 3D and scale, and add sign
    return sqrt( (d2+q.z*q.z)/m2 ) * sign(max(q.z,-p.y));;
}

// la,lb=semi axis, h=height, ra=corner
float sdRhombus(float3 p, float la, float lb, float h, float ra)
{
    p = abs(p);
    float2 b = float2(la,lb);
    float f = clamp( (ndot(b,b-2.0*p.xz))/dot(b,b), -1.0, 1.0 );
	float2 q = float2(length(p.xz-0.5*b*float2(1.0-f,1.0+f))*sign(p.x*b.y+p.z*b.x-b.x*b.y)-ra, p.y-h);
    return min(max(q.x,q.y),0.0) + length(max(q,0.0));
}

float sdHorseshoe( float3 p, float2 c, float r, float le, float2 w )
{
    p.x = abs(p.x);
    float l = length(p.xy);
    p.xy = float2x2(-c.x, c.y, 
              c.y, c.x)*p.xy;
    p.xy = float2((p.y>0.0 || p.x>0.0)?p.x:l*sign(-c.x),
                (p.x>0.0)?p.y:l );
    p.xy = float2(p.x,abs(p.y-r))-float2(le,0.0);
    
    float2 q = float2(length(max(p.xy,0.0)) + min(0.0,max(p.x,p.y)),p.z);
    float2 d = abs(q) - w;
    return min(max(d.x,d.y),0.0) + length(max(d,0.0));
}

float sdU( float3 p, float r, float le, float2 w )
{
    p.x = (p.y>0.0) ? abs(p.x) : length(p.xy);
    p.x = abs(p.x-r);
    p.y = p.y - le;
    float k = max(p.x,p.y);
    float2 q = float2( (k<0.0) ? -k : length(max(p.xy,0.0)), abs(p.z) ) - w;
    return length(max(q,0.0)) + min(max(q.x,q.y),0.0);
}

//------------------------------------------------------------------

float2 opU( float2 d1, float2 d2 )
{
	return (d1.x<d2.x) ? d1 : d2;
}

//------------------------------------------------------------------

#define ZERO 0

//------------------------------------------------------------------

float2 map( float3 pos )
{
    float2 res = float2( pos.y, 0.0 );

    // bounding box
    if( sdBox( pos-float3(-2.0,0.3,0.25),float3(0.3,0.3,1.0) )<res.x )
    {
      res = opU( res, float2( sdSphere(    pos-float3(-2.0,0.25, 0.0), 0.25 ), 26.9 ) );
	  res = opU( res, float2( sdRhombus(  (pos-float3(-2.0,0.25, 1.0)).xzy, 0.15, 0.25, 0.04, 0.08 ),17.0 ) );
    }

    // bounding box
    if( sdBox( pos-float3(0.0,0.3,-1.0),float3(0.35,0.3,2.5) )<res.x )
    {
	res = opU( res, float2( sdCappedTorus((pos-float3( 0.0,0.30, 1.0))*float3(1,-1,1), float2(0.866025,-0.5), 0.25, 0.05), 25.0) );
    res = opU( res, float2( sdBoxFrame(    pos-float3( 0.0,0.25, 0.0), float3(0.3,0.25,0.2), 0.025 ), 16.9 ) );
	res = opU( res, float2( sdCone(        pos-float3( 0.0,0.45,-1.0), float2(0.6,0.8),0.45 ), 55.0 ) );
    res = opU( res, float2( sdCappedCone(  pos-float3( 0.0,0.25,-2.0), 0.25, 0.25, 0.1 ), 13.67 ) );
    res = opU( res, float2( sdSolidAngle(  pos-float3( 0.0,0.00,-3.0), float2(3,4)/5.0, 0.4 ), 49.13 ) );
    }

    // bounding box
    if( sdBox( pos-float3(1.0,0.3,-1.0),float3(0.35,0.3,2.5) )<res.x )
    {
	res = opU( res, float2( sdTorus(      (pos-float3( 1.0,0.30, 1.0)).xzy, float2(0.25,0.05) ), 7.1 ) );
    res = opU( res, float2( sdBox(         pos-float3( 1.0,0.25, 0.0), float3(0.3,0.25,0.1) ), 3.0 ) );
    res = opU( res, float2( sdCapsule(     pos-float3( 1.0,0.00,-1.0),float3(-0.1,0.1,-0.1), float3(0.2,0.4,0.2), 0.1  ), 31.9 ) );
	res = opU( res, float2( sdCylinder(    pos-float3( 1.0,0.25,-2.0), float2(0.15,0.25) ), 8.0 ) );
    res = opU( res, float2( sdHexPrism(    pos-float3( 1.0,0.2,-3.0), float2(0.2,0.05) ), 18.4 ) );
    }

    // bounding box
    if( sdBox( pos-float3(-1.0,0.35,-1.0),float3(0.35,0.35,2.5))<res.x )
    {
	res = opU( res, float2( sdPyramid(    pos-float3(-1.0,-0.6,-3.0), 1.0 ), 13.56 ) );
	res = opU( res, float2( sdOctahedron( pos-float3(-1.0,0.15,-2.0), 0.35 ), 23.56 ) );
    res = opU( res, float2( sdTriPrism(   pos-float3(-1.0,0.15,-1.0), float2(0.3,0.05) ),43.5 ) );
    res = opU( res, float2( sdEllipsoid(  pos-float3(-1.0,0.25, 0.0), float3(0.2, 0.25, 0.05) ), 43.17 ) );
    res = opU( res, float2( sdHorseshoe(  pos-float3(-1.0,0.25, 1.0), float2(cos(1.3),sin(1.3)), 0.2, 0.3, float2(0.03,0.08) ), 11.5 ) );
    }

    // bounding box
    if( sdBox( pos-float3(2.0,0.3,-1.0),float3(0.35,0.3,2.5) )<res.x )
    {
    res = opU( res, float2( sdOctogonPrism(pos-float3( 2.0,0.2,-3.0), 0.2, 0.05), 51.8 ) );
    res = opU( res, float2( sdCylinder(    pos-float3( 2.0,0.14,-2.0), float3(0.1,-0.1,0.0), float3(-0.2,0.35,0.1), 0.08), 31.2 ) );
	res = opU( res, float2( sdCappedCone(  pos-float3( 2.0,0.09,-1.0), float3(0.1,0.0,0.0), float3(-0.2,0.40,0.1), 0.15, 0.05), 46.1 ) );
    res = opU( res, float2( sdRoundCone(   pos-float3( 2.0,0.15, 0.0), float3(0.1,0.0,0.0), float3(-0.1,0.35,0.1), 0.15, 0.05), 51.7 ) );
    res = opU( res, float2( sdRoundCone(   pos-float3( 2.0,0.20, 1.0), 0.2, 0.1, 0.3 ), 37.0 ) );
    }
    
    return res;
}

// https://iquilezles.org/articles/boxfunctions
float2 iBox( float3 ro, float3 rd, float3 rad ) 
{
    float3 m = 1.0/rd;
    float3 n = m*ro;
    float3 k = abs(m)*rad;
    float3 t1 = -n - k;
    float3 t2 = -n + k;
	return float2( max( max( t1.x, t1.y ), t1.z ),
	             min( min( t2.x, t2.y ), t2.z ) );
}

float2 raycast( float3 ro, float3 rd )
{
    float2 res = float2(-1.0,-1.0);

    float tmin = 1.0;
    float tmax = 20.0;

    // raytrace floor plane
    float tp1 = (0.0-ro.y)/rd.y;
    if( tp1>0.0 )
    {
        tmax = min( tmax, tp1 );
        res = float2( tp1, 1.0 );
    }
    //else return res;
    
    // raymarch primitives   
    float2 tb = iBox( ro-float3(0.0,0.4,-0.5), rd, float3(2.5,0.41,3.0) );
    if( tb.x<tb.y && tb.y>0.0 && tb.x<tmax)
    {
        //return float2(tb.x,2.0);
        tmin = max(tb.x,tmin);
        tmax = min(tb.y,tmax);

        float t = tmin;
        for( int i=0; i<70 && t<tmax; i++ )
        {
            float2 h = map( ro+rd*t );
            if( abs(h.x)<(0.0001*t) )
            { 
                res = float2(t,h.y); 
                break;
            }
            t += h.x;
        }
    }
    
    return res;
}

// https://iquilezles.org/articles/rmshadows
float calcSoftshadow( float3 ro, float3 rd, float mint, float tmax )
{
    // bounding volume
    float tp = (0.8-ro.y)/rd.y; if( tp>0.0 ) tmax = min( tmax, tp );

    float res = 1.0;
    float t = mint;
    for( int i=ZERO; i<24; i++ )
    {
		float h = map( ro + rd*t ).x;
        float s = clamp(8.0*h/t,0.0,1.0);
        res = min( res, s );
        t += clamp( h, 0.01, 0.2 );
        if( res<0.004 || t>tmax ) break;
    }
    res = clamp( res, 0.0, 1.0 );
    return res*res*(3.0-2.0*res);
}

// https://iquilezles.org/articles/normalsSDF
float3 calcNormal( float3 pos )
{
#if 0
    // do NOT call map() many times inside calcNormal()
    float2 e = float2(1.0,-1.0)*0.5773*0.0005;
    return normalize( e.xyy*map( pos + e.xyy ).x + 
					  e.yyx*map( pos + e.yyx ).x + 
					  e.yxy*map( pos + e.yxy ).x + 
					  e.xxx*map( pos + e.xxx ).x );
#else
    // instead put it only once and in a loop to prevet
    // code expansion - inspired by tdhooper and klems - a way to prevent the compiler from inlining map() 4 times
    float3 n = float3(0.0);
    for( int i=ZERO; i<4; i++ )
    {
        float3 e = 0.5773*(2.0*float3((((i+3)>>1)&1),((i>>1)&1),(i&1))-1.0);
        n += e*map(pos+0.0005*e).x;
      //if( n.x+n.y+n.z>100.0 ) break;
    }
    return normalize(n);
#endif    
}

// https://iquilezles.org/articles/nvscene2008/rwwtt.pdf
float calcAO( float3 pos, float3 nor )
{
	float occ = 0.0;
    float sca = 1.0;
    for( int i=ZERO; i<5; i++ )
    {
        float h = 0.01 + 0.12*float(i)/4.0;
        float d = map( pos + h*nor ).x;
        occ += (h-d)*sca;
        sca *= 0.95;
        if( occ>0.35 ) break;
    }
    return clamp( 1.0 - 3.0*occ, 0.0, 1.0 ) * (0.5+0.5*nor.y);
}

// https://iquilezles.org/articles/checkerfiltering
float checkersGradBox( float2 p, float2 dpdx, float2 dpdy )
{
    // filter kernel
    float2 w = abs(dpdx)+abs(dpdy) + 0.001;
    // analytical integral (box filter)
    float2 i = 2.0*(abs(fract((p-0.5*w)*0.5)-0.5)-abs(fract((p+0.5*w)*0.5)-0.5))/w;
    // xor pattern
    return 0.5 - 0.5*i.x*i.y;                  
}

float3 render( float3 ro, float3 rd, float3 rdx, float3 rdy )
{ 
    // background
    float3 col = float3(0.7, 0.7, 0.9) - max(rd.y,0.0)*0.3;
    
    // raycast scene
    float2 res = raycast(ro,rd);
    float t = res.x;
	float m = res.y;
    if( m>-0.5 )
    {
        float3 pos = ro + t*rd;
        float3 nor = (m<1.5) ? float3(0.0,1.0,0.0) : calcNormal( pos );
        float3 ref = reflect( rd, nor );
        
        // material        
        col = 0.2 + 0.2*sin( m*2.0 + float3(0.0,1.0,2.0) );
        float ks = 1.0;
        
        if( m<1.5 )
        {
            // project pixel footprint into the plane
            float3 dpdx = ro.y*(rd/rd.y-rdx/rdx.y);
            float3 dpdy = ro.y*(rd/rd.y-rdy/rdy.y);

            float f = checkersGradBox( 3.0*pos.xz, 3.0*dpdx.xz, 3.0*dpdy.xz );
            col = 0.15 + f*float3(0.05);
            ks = 0.4;
        }

        // lighting
        float occ = calcAO( pos, nor );
        
		float3 lin = float3(0.0);

        // sun
        {
            float3  lig = normalize( float3(-0.5, 0.4, -0.6) );
            float3  hal = normalize( lig-rd );
            float dif = clamp( dot( nor, lig ), 0.0, 1.0 );
          //if( dif>0.0001 )
        	      dif *= calcSoftshadow( pos, lig, 0.02, 2.5 );
			float spe = pow( clamp( dot( nor, hal ), 0.0, 1.0 ),16.0);
                  spe *= dif;
                  spe *= 0.04+0.96*pow(clamp(1.0-dot(hal,lig),0.0,1.0),5.0);
                //spe *= 0.04+0.96*pow(clamp(1.0-sqrt(0.5*(1.0-dot(rd,lig))),0.0,1.0),5.0);
            lin += col*2.20*dif*float3(1.30,1.00,0.70);
            lin +=     5.00*spe*float3(1.30,1.00,0.70)*ks;
        }
        // sky
        {
            float dif = sqrt(clamp( 0.5+0.5*nor.y, 0.0, 1.0 ));
                  dif *= occ;
            float spe = smoothstep( -0.2, 0.2, ref.y );
                  spe *= dif;
                  spe *= 0.04+0.96*pow(clamp(1.0+dot(nor,rd),0.0,1.0), 5.0 );
          //if( spe>0.001 )
                  spe *= calcSoftshadow( pos, ref, 0.02, 2.5 );
            lin += col*0.60*dif*float3(0.40,0.60,1.15);
            lin +=     2.00*spe*float3(0.40,0.60,1.30)*ks;
        }
        // back
        {
        	float dif = clamp( dot( nor, normalize(float3(0.5,0.0,0.6))), 0.0, 1.0 )*clamp( 1.0-pos.y,0.0,1.0);
                  dif *= occ;
        	lin += col*0.55*dif*float3(0.25,0.25,0.25);
        }
        // sss
        {
            float dif = pow(clamp(1.0+dot(nor,rd),0.0,1.0),2.0);
                  dif *= occ;
        	lin += col*0.25*dif*float3(1.00,1.00,1.00);
        }
        
		col = lin;

        col = mix( col, float3(0.7,0.7,0.9), 1.0-exp( -0.0001*t*t*t ) );
    }

	return float3( clamp(col,0.0,1.0) );
}

float3x3 setCamera( float3 ro, float3 ta, float cr )
{
	float3 cw = normalize(ta-ro);
	float3 cp = float3(sin(cr), cos(cr),0.0);
	float3 cu = normalize( cross(cw,cp) );
	float3 cv =          ( cross(cu,cw) );
    return float3x3( cu, cv, cw );
}

void mainImage(thread float4 &fragColor, float2 fragCoord,
               constant ShaderUniforms &uniforms)
{
    float2 mo = uniforms.mouse.xy/uniforms.resolutionTime.xy;
	float time = 32.0 + uniforms.resolutionTime.z*1.5;

    // camera	
    float3 ta = float3( 0.25, -0.75, -0.75 );
    float3 ro = ta + float3( 4.5*cos(0.1*time + 7.0*mo.x), 2.2, 4.5*sin(0.1*time + 7.0*mo.x) );
    // camera-to-world transformation
    float3x3 ca = setCamera( ro, ta, 0.0 );

    float3 tot = float3(0.0);
#if AA>1
    for( int m=ZERO; m<AA; m++ )
    for( int n=ZERO; n<AA; n++ )
    {
        // pixel coordinates
        float2 o = float2(float(m),float(n)) / float(AA) - 0.5;
        float2 p = (2.0*(fragCoord+o)-uniforms.resolutionTime.xy)/uniforms.resolutionTime.y;
#else    
        float2 p = (2.0*fragCoord-uniforms.resolutionTime.xy)/uniforms.resolutionTime.y;
#endif

        // focal length
        const float fl = 2.5;
        
        // ray direction
        float3 rd = ca * normalize( float3(p,fl) );

         // ray differentials
        float2 px = (2.0*(fragCoord+float2(1.0,0.0))-uniforms.resolutionTime.xy)/uniforms.resolutionTime.y;
        float2 py = (2.0*(fragCoord+float2(0.0,1.0))-uniforms.resolutionTime.xy)/uniforms.resolutionTime.y;
        float3 rdx = ca * normalize( float3(px,fl) );
        float3 rdy = ca * normalize( float3(py,fl) );
        
        // render	
        float3 col = render( ro, rd, rdx, rdy );

        // gain
        // col = col*3.0/(2.5+col);
        
		// gamma
        col = pow( col, float3(0.4545) );

        tot += col;
#if AA>1
    }
    tot /= float(AA*AA);
#endif
    
    fragColor = float4( tot, 1.0 );
}

vertex float4 fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2((vertexID << 1) & 2, vertexID & 2);
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

fragment float4 sdfPrimitivesFragment(
    float4 position [[position]], constant ShaderUniforms &uniforms [[buffer(0)]]) {
    float4 color = float4(0.0);
    // Metal fragment coordinates start at the top; Shadertoy starts at the bottom.
    mainImage(color, float2(position.x, uniforms.resolutionTime.y - position.y), uniforms);
    return color;
}
