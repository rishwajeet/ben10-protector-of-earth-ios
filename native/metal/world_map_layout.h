#pragma once

// Exact RBNEG9 source identities from the 13 October five-region native
// source batch. Fingerprints only; proprietary artwork stays outside Git.
enum class MapProfile { Region0,Region1,Region2,Region3,Region4,Paper,BlankPaper,Heading,HeadingCap,DetailPanel,Badge,Score,Glow,BluePin,RedPin,SkullPin,HeadingText,HintText, Photo, Unknown };
struct MapTextureProfile { const char* primary; const char* auxiliary; MapProfile role; };
static constexpr MapTextureProfile kMapTextures[] = {
    {"256x256-7355bfa0a7b6fc895720e32a1434ed7c5e8e3b666271f5d9c04165a30a417637", "256x256-e8372b325a0117805611f5986510494bec04c451489c1366be9f124bcff2e7e6", MapProfile::Region0},
    {"256x256-533f9e073075605745779a6e6409d7a4d7f58b9b7efc1b54bcf4ac4117b2c355", "256x256-6f24f7322c4a79b3eba673ba170042b80b1e4c6415de8e29f56446898d180440", MapProfile::Region1},
    {"256x256-d977c2e035d229bdbfe72db7631e379926db5454c385a36b7c1cfb7930233cc5", "256x256-61ac23db069bbef79c9f3498bc48e074ddfd14e044c88cc10548c133a82e554d", MapProfile::Region2},
    {"256x256-579d4b2451ff1ff660b438ec065f19e4cb50bc0b099e1f700933ab0567f9020d", "256x256-8d7ad5863eb92a3434f05a37e219bc5c68063ea11d8003a6da22bd8880f34501", MapProfile::Region3},
    {"128x256-220e67bc002b996fa8f516fcf8f03d485b8c7e74f047ca3485fffaddb4aebfb4", "128x256-0380c7f4d37464cd44d935f97d54770f08c3711b7be9b4e2f833de42c6023440", MapProfile::Region4},
    {"256x256-4e4d511d593395f1b139e16351a0cb17a244cb7b09bc7d24fb80797c882b2173", "256x256-9102c46823f34a392dfdb60ffdda5a32477f6469032f7d2752a995393cf4cccf", MapProfile::Paper},
    {"256x256-a53dd639e140389ba3ce09c1b2aaec586bca7676d132e1d6a3a13af68ad6d7fc", "256x256-9102c46823f34a392dfdb60ffdda5a32477f6469032f7d2752a995393cf4cccf", MapProfile::BlankPaper},
    {"32x128-74f1d8612646f3bd9c52055471f33d653f4c6bcb096b7e2383be7eaa36ccb709", "32x128-df38508fc683288e8ab60fbfaf22e590a48b1ff8c86bf62fa223c45348e1728b", MapProfile::Heading},
    {"32x128-67ae129af7de5970b64949de1f1aebb62246da783475cfd56d355d63d70e0ada", "32x128-1dd42aed72272b62113d5ad1ddeaa6926a1a5f2f2f9b78ae598ec0e30a702f83", MapProfile::HeadingCap},
    {"256x256-11a5d09eb8ccf7edbdadc6e04d0f08149d597a1a006c79b47580a818f1f53bd3", "256x256-e4bfe4f7dab65c2c505355db8e04d0378b323b3d52f922ec7ed85b028e09a92f", MapProfile::DetailPanel},
    {"64x64-8a1c18282733cd51935397ddfc0e46772ffa65116ae8f4a826693106d3d55e3f", "64x64-bf5968126006f07c2df00e261c803e672b6a527bcc4e6e25096e7f2d9823373f", MapProfile::Badge},
    {"32x64-a97557204f035d4d63fa3ce6ba53a6b2a45ffd7143ddf3eb92f315d55770bf58", "32x64-4dc683064afc3059ad34dd196bf1d9f05ecf4d9b69deb3d5c1662ccef23c1971", MapProfile::Score},
    {"256x256-2e766909807da93264b6f890785e5973c3f3582b1aa34f974a777bea9817ddc3", "256x256-8120abdc7fd496bc41a85e4705919c512b9eb709169493e474a548a2a145395c", MapProfile::Glow},
    {"32x32-21815abbe4348c945e7df68983e22064431c66b42a08ced0ff6820eb4d7c7302", "32x32-dd4b14355ffe002ddc3ea210c2ba4332d239f1eed94d3c1d8235270479d3ec4d", MapProfile::BluePin},
    {"32x32-2b8bcd06b9300fc6c8928af6b364899bf1f6aea327c40cdf8a3620371b8ae01d", "32x32-9f9ea78049c39d3b5d8dde0e2957f91060acbe1d7f732f276c048b8daf9bf9f6", MapProfile::RedPin},
    {"32x32-072312d187ddf26684ec3736238ff67b070a365d7aed06d68a24ee609f9dcb69", "32x32-93645b068414e1f26367b0ef09197dca483b5faa19d16b54fe2f1d484d2f41f3", MapProfile::SkullPin},
    {"256x512-011e4572640c9b41459963c6c9884dc724e0bf94a9836ad76651755ab1edc05d", "", MapProfile::HeadingText},
    {"256x512-7f1c5d69d0069b594140d68077b3327041f518ef8af8975c07de443b1e421faa", "", MapProfile::HintText},
};
static constexpr const char* kMapPhotos[] = {
    "256x256-0ba087c23c4e249a53ac421f79d4f9955d52de23003aeafdc5addf1775acfe84",
    "256x256-39b5e6c4cc448bb149b16eeec47f380711bcbe4d37e44a240dab2baddaad70c3",
    "256x256-18606c67d76a96eb6f06ba5d9c61e3ce12d24b7f8064b764abb677e1a295729c",
    "256x256-c3c04e6d913e1b3754544294776e7e212a514b61b7ce6a8ef6b6b1b9bfa7e85e",
    "256x256-16dd05e4df764be7d611251b4e39276b9ec38cdc0894693597b81b150f59c046",
    "256x256-e0df0a826b4a35cc17a2dbfd8b0a82dad96d4ad15628dcf9a5a9ec79f3b1cd32",
    "256x256-17f2735fdbdf5b90feb38afd0ad9dcaae5810fcae44baaceca6f9da01652fc67",
    "256x256-a3cb372c3695a4272d410350990fd6180e22c26e9cb4dcdfb1e50230ef134f36",
    "256x256-91ca1249aaca2ce135465902ee4ae705982ef9ce277443febfcc012b2c9e2fe6",
    "256x256-b0f96b03574463bbeef79f09fbfbbd22528b61243d2fa3ec1bdb5824118e04ef",
    "256x256-7b6d4fb6a5ca6d2a19499041bee86822eae42591cf702c7de8e69d31b708f3de",
    "256x256-6a1c03ad2ca361c5605635be5bb15e3d3454e81019a842003c45101f53550d5b",
    "256x256-f1a54ff3b854cdc5c1768e2ef999b0685c3d7ca70cb972286228df168524bd3d",
    "256x256-4deee237c6a012d44979d2396e46282d4db2f9dc1be0887b7b49939cf38db199",
    "256x256-060634004a0314d12e13395180c53b6dede0fb7d973acfcf231bb81e68c05332",
    "256x256-eb59a533c73cc76b8eaffdf8b4654eb0f518a2fa65d504c33c323dd2373e8f5e",
    "256x256-1e4c9a7f362832238490822cb5181672fcdf35bf7bfe5ea0ca5e46d74e076d04",
    "256x256-09979fe12e8b3d7439f68f36a94f48c209543ae664d91d6764b1e757ca3460e0",
    "256x256-ac07e896e2da15ad360bf8b15bac8aaace01fabf5330cd305829497a0cc13646",
    "256x256-0dfa9f51c71a079e898feb6b954f2b4062b5b259838655f2d5c42c843d40894f",
    "256x256-7c21bc0c2d456de9409d31550b2acd33f886cae31993c04afb28fb439d92da3b",
    "256x256-7ae1831b02cf61f4f6ef1a39ccd17481eb90eb4164b4a11f00b29e7ed3704e94",
    "256x256-3284e9d204d22c0d65bb27ddae9f377d0a3abad4c0035fb9491baa3eda37cc71",
    "256x256-39d7f3a9a9294b4cf9a662707644d065e29d2b81fb5f6bc793c9fdd4eeb23d5a",
};

// Mean unselected paper centres, in the complete 5 x 4 map's tile units.
// Measuring across all eleven overview/detail captures cancels the guest's
// integer rounding. Selection animation must never choose the cluster fit.
static constexpr float kMapAnchors[24][2] = {
    {1.140584f,2.321035f},{1.577980f,1.875089f},{1.031125f,1.875089f},
    {.644413f,2.324490f},{.461019f,1.875089f},{.375091f,1.468818f},
    {.425866f,.957233f},{1.109206f,.914423f},{.609053f,.539087f},
    {1.640569f,.996521f},{2.858658f,.953684f},{2.394386f,1.269732f},
    {3.347814f,1.308790f},{3.324136f,.785205f},{2.359326f,.761754f},
    {2.589849f,2.175663f},{2.406280f,2.664464f},{3.386725f,2.683492f},
    {2.862904f,3.218999f},{3.324271f,2.144530f},{4.046919f,2.168535f},
    {4.046919f,2.688088f},{4.526942f,2.688088f},{4.527264f,2.168480f},
};

struct MapSourceBounds { float left,top,right,bottom; };
static MapSourceBounds MapBounds(const LiveDraw& draw) {
    MapSourceBounds b{INFINITY,INFINITY,-INFINITY,-INFINITY};
    for(const auto& v:draw.vertices) {
        const float x=(v.position[0]+1)*320,y=(1-v.position[1])*224;
        b.left=std::min(b.left,x);b.right=std::max(b.right,x);
        b.top=std::min(b.top,y);b.bottom=std::max(b.bottom,y);
    }
    return b;
}
static bool MapNear(float a,float b,float tolerance=.01f) {
    return std::isfinite(a)&&std::isfinite(b)&&std::abs(a-b)<=tolerance;
}
static bool MapSameBounds(const MapSourceBounds& a,const MapSourceBounds& b,float tolerance=.01f) {
    return MapNear(a.left,b.left,tolerance)&&MapNear(a.top,b.top,tolerance)&&
        MapNear(a.right,b.right,tolerance)&&MapNear(a.bottom,b.bottom,tolerance);
}
static bool MapQuad(const LiveDraw& draw,bool font=false) {
    if(!FrontendDrawStateMatches(draw,font?FrontendRole::Text:FrontendRole::MenuArt)||
        draw.viewportX!=0||draw.viewportY!=0||draw.viewportWidth!=640)return false;
    const auto b=MapBounds(draw);
    if(b.right<b.left||b.bottom<b.top||((b.right==b.left)!=(b.bottom==b.top)))return false;
    if(font&&(b.right==b.left||b.bottom==b.top))return false;
    for(const auto& v:draw.vertices)
        if(!MapNear(v.position[2],.00625002384f,.00001f))return false;
    if(font)return true; // Font state validates each atlas coordinate and topology.
    constexpr unsigned expanded[]={0,1,2,0,2,3};
    constexpr float uv[][2]={{0,0},{1,0},{1,1},{0,1}};
    const bool flipped=draw.vertices[0].position[0]>draw.vertices[1].position[0];
    for(size_t i=0;i<draw.vertices.size();++i) {
        const auto& v=draw.vertices[i];const auto c=draw.indexed?i:expanded[i];
        if(!MapNear((v.position[0]+1)*320,(bool(uv[c][0])!=flipped)?b.right:b.left)||
            !MapNear((1-v.position[1])*224,uv[c][1]?b.bottom:b.top))return false;
        for(size_t t=0;t<draw.fragment.stageCount;++t)
            for(size_t a=0;a<2;++a)if(!MapNear(v.uv[t][a],uv[c][a],.00001f))return false;
        for(size_t a=0;a<4;++a)if(v.color[a]!=draw.vertices[0].color[a])return false;
    }
    return true;
}

struct MapLayoutAdmission {
    bool enabled=false;
    bool country=false;
    int region=-1,selected=-1;
    size_t rejectedDraw=0;
    const char* reason="not-regional-map-overview";
    float tileX=0,tileY=0,tileWidth=0,tileHeight=0;
    float titleLeft=88,titleTop=32,titleHeight=60;
    // -1 retains the guest draw, 0..23 are complete card units, 24 title,
    // 25..27 are help rows in their original top-to-bottom order.
    std::vector<int> groups;
    std::array<MapSourceBounds,3> hints{};
    size_t hintCount=0;
};

static MapLayoutAdmission IdentifyMapLayout(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>& copies,bool knownWorldMap=false) {
    MapLayoutAdmission result;
    if(draws.size()<100||draws.size()>192||(!knownWorldMap&&!IdentifyWorldMap(draws,copies)))return result;
    constexpr MapSourceBounds countryRegions[]={{5,145,266,313},{3,11,271,189},
        {217,9,524,199},{203,151,528,397},{472,32,694,410}};
    result.country=MapSameBounds(MapBounds(draws[24]),countryRegions[0],1.1f);
    result.groups.assign(draws.size(),-1);
    std::vector<MapProfile> profiles(draws.size(),MapProfile::Unknown);
    std::vector<int> photoOrdinals(draws.size(),-1);
    std::vector<size_t> papers,photos,pins,counters,headings,fonts,hints;
    size_t glow=SIZE_MAX,panel=SIZE_MAX;
    std::map<std::tuple<const u8*,size_t,u32,u32>,NSString*> keys;
    auto key=[&](const LiveDraw& draw,size_t stage)->NSString* {
        const auto& pixels=TexturePixels(draw,stage);
        auto id=std::make_tuple(pixels.data(),pixels.size(),draw.textureWidths[stage],draw.textureHeights[stage]);
        auto it=keys.find(id);if(it!=keys.end())return it->second;
        NSString* value=InterfaceTextureKey(pixels,draw.textureWidths[stage],draw.textureHeights[stage]);
        keys.emplace(id,value);return value;
    };
    for(size_t i=24;i<draws.size();++i) {
        result.rejectedDraw=i;
        const auto& d=draws[i];
        // Cheap state preflight before hashes; exact tuples still own identity.
        const bool font=d.textureFormats[0]==9;
        if(!MapQuad(d,font)){result.reason="map-render-state-or-quad";return result;}
        NSString* primary=key(d,0),*aux=d.fragment.stageCount==2?key(d,1):nil;
        auto& p=profiles[i];
        for(const auto& candidate:kMapTextures)
            if([primary isEqualToString:@(candidate.primary)]&&
                ((!candidate.auxiliary[0]&&!aux)||[aux isEqualToString:@(candidate.auxiliary)]))p=candidate.role;
        if(p==MapProfile::Unknown&&!aux)
            for(int n=0;n<24;++n)if([primary isEqualToString:@(kMapPhotos[n])]){p=MapProfile::Photo;photoOrdinals[i]=n;}
        if(p==MapProfile::Unknown){result.reason="unknown-map-source";return result;}
        const bool expectedFont=p==MapProfile::HeadingText||p==MapProfile::HintText;
        if(font!=expectedFont)return result;
        if(!font&&p!=MapProfile::HeadingCap&&d.vertices[0].position[0]>d.vertices[1].position[0])return result;
        if(i<29) {
            if((int)p!=(int)(i-24))return result;
            if(result.country&&!MapSameBounds(MapBounds(d),countryRegions[i-24],1.1f))return result;
            const auto& c=d.vertices[0].color;
            if(c[0]!=1||c[1]!=1)return result;
            if(c[3]==1&&c[2]==1) {
                if(result.region>=0)return result;
                result.region=(int)i-24;
                constexpr MapSourceBounds active[]={{0,0,640,448},{0,0,640,448},
                    {0,0,639,448},{18,-17,621,447},{116,-335,586,566}};
                if(!result.country&&!MapSameBounds(MapBounds(d),active[i-24],1.1f))return result;
            } else if(!MapNear(c[3],75.f/255,.00001f)||!MapNear(c[2],127.f/255,.00001f))return result;
            continue;
        }
        if((int)p<5)return result;
        if(p==MapProfile::Paper||p==MapProfile::BlankPaper)papers.push_back(i);
        else if(p==MapProfile::Photo)photos.push_back(i);
        else if(p==MapProfile::BluePin||p==MapProfile::RedPin||p==MapProfile::SkullPin)pins.push_back(i);
        else if(p==MapProfile::Badge||p==MapProfile::Score)counters.push_back(i);
        else if(p==MapProfile::Heading||p==MapProfile::HeadingCap)headings.push_back(i);
        else if(p==MapProfile::HeadingText)fonts.push_back(i);
        else if(p==MapProfile::HintText)hints.push_back(i);
        else if(p==MapProfile::Glow){if(glow!=SIZE_MAX)return result;glow=i;}
        else if(p==MapProfile::DetailPanel){if(panel!=SIZE_MAX)return result;panel=i;}
        for(const auto& v:d.vertices) {
            // Stable overview only: do not reorganize a region crossfade or
            // a postcard entering/leaving detail. Keep all source alpha.
            if(v.color[3]!=0&&v.color[3]!=1){result.reason="map-transition";return result;}
            if(v.color[0]!=1||v.color[1]!=1||v.color[2]!=1)return result;
        }
    }
    result.reason="map-cohort-counts";
    if(result.region<0||papers.size()!=24||photos.size()!=24||pins.size()!=24||
        headings.size()!=6||fonts.size()!=1||hints.size()<2||hints.size()>3||
        glow==SIZE_MAX||panel==SIZE_MAX)return result;
    if(result.country) {
        result.reason="country-map-component-geometry";
        if(hints.size()!=2||draws[panel].vertices[0].color[3]!=0||draws[glow].vertices[0].color[3]!=0)return result;
        for(const auto& cohort:{papers,photos,counters})for(size_t i:cohort)
            if(draws[i].vertices[0].color[3]!=0)return result;
        constexpr MapSourceBounds banner[]={{-180,350,220,410},{-212,350,-180,410},{220,350,252,410}};
        for(size_t n=0;n<headings.size();++n) {
            const auto& d=draws[headings[n]];
            if(profiles[headings[n]]!=(n%3==0?MapProfile::Heading:MapProfile::HeadingCap)||
                d.vertices[0].color[3]!=(n>=3?1:0)||
                (d.vertices[0].position[0]>d.vertices[1].position[0])!=(n%3==2))return result;
            if(n>=3) {
                if(!MapSameBounds(MapBounds(d),banner[n-3]))return result;
                result.groups[headings[n]]=24;
            }
        }
        const auto text=MapBounds(draws[fonts[0]]);
        if(!MapNear(text.left,20)||!MapNear(text.top,354)||!MapNear(text.bottom,415)||
            text.right>220||draws[fonts[0]].vertices[0].color[3]!=1)return result;
        for(size_t i:pins) {
            const auto b=MapBounds(draws[i]);
            if(b.left<0||b.right>640||b.top<0||b.bottom>448)return result;
        }
        for(size_t i:hints) {
            const auto b=MapBounds(draws[i]);
            if(b.left<430||b.right>530||!MapNear(b.bottom-b.top,32)||
                !(MapNear(b.top,336)||MapNear(b.top,364)))return result;
        }
        result.groups[fonts[0]]=24;
        result.titleLeft=-212;result.titleTop=350;result.titleHeight=65;
        result.enabled=true;result.reason="complete-country-title";
        return result;
    }
    if(draws[panel].vertices[0].color[3]!=0){result.reason="detail-retains-source-layout";return result;}
    const auto tile=MapBounds(draws[0]);
    result.tileX=tile.left;result.tileY=tile.top;
    result.tileWidth=(MapBounds(draws[4]).right-tile.left)/5;
    result.tileHeight=(MapBounds(draws[15]).bottom-tile.top)/4;
    if(result.tileWidth<100||result.tileWidth>500||result.tileHeight<100||result.tileHeight>500)return result;
    result.selected=photoOrdinals[photos.back()];
    const int first=result.region*5,last=std::min(first+5,24);
    result.reason="map-paper-photo-geometry";
    if(result.selected<first||result.selected>=last)return result;
    std::array<MapSourceBounds,24> cardBounds{};
    unsigned mask=0;
    for(size_t i=0;i<24;++i) {
        result.rejectedDraw=papers[i];
        const int ordinal=photoOrdinals[photos[i]];
        if(ordinal<0||(mask&(1u<<ordinal))||papers[i]>=photos[i])return result;
        mask|=1u<<ordinal;
        const bool blank=ordinal>=20?ordinal>=22:ordinal%5>=3;
        if(profiles[papers[i]]!=(blank?MapProfile::BlankPaper:MapProfile::Paper))return result;
        const auto b=MapBounds(draws[papers[i]]),p=MapBounds(draws[photos[i]]);
        const float w=b.right-b.left,h=b.bottom-b.top;
        const bool collapsed=w==0&&h==0;
        if(collapsed) {
            // Unavailable locations retain their exact source tuple but have
            // no area. Do not turn hidden progress into visible postcards.
            if(ordinal==result.selected||p.left!=p.right||p.top!=p.bottom||
                draws[photos[i]].vertices[0].color[3]!=0||
                !MapNear(p.left,b.left+.0075f*result.tileWidth,1.6f)||
                !MapNear(p.top,b.top-.05f*result.tileHeight,1.6f))return result;
        } else {
            if(w<.43f*result.tileWidth||w>.56f*result.tileWidth||
                h<.43f*result.tileHeight||h>.56f*result.tileHeight)return result;
            if(!MapSameBounds(p,{b.left+.11f*w,b.top+.08f*h,b.right-.075f*w,b.top+.715f*h},1.6f))return result;
        }
        const float ax=tile.left+kMapAnchors[ordinal][0]*result.tileWidth;
        const float ay=tile.top+kMapAnchors[ordinal][1]*result.tileHeight;
        const float tolerance=ordinal==result.selected?6.f:2.f;
        if(!MapNear((b.left+b.right)/2,ax,tolerance)||!MapNear((b.top+b.bottom)/2,ay,tolerance))return result;
        // An available but unfinished level can show paper and a pin before
        // its photograph is revealed. Never equate paper visibility to progress.
        if(draws[photos[i]].vertices[0].color[3]>draws[papers[i]].vertices[0].color[3])return result;
        if(ordinal<first||ordinal>=last) {
            if(draws[photos[i]].vertices[0].color[3]!=0)return result;
        }
        cardBounds[ordinal]=collapsed?MapSourceBounds{ax-.244f*result.tileWidth,ay-.244f*result.tileHeight,
            ax+.244f*result.tileWidth,ay+.244f*result.tileHeight}:b;
        if(!collapsed)result.groups[papers[i]]=result.groups[photos[i]]=ordinal;
    }
    if(mask!=0xffffffu||draws[papers.back()].vertices[0].color[3]!=1||draws[glow].vertices[0].color[3]!=1)return result;
    // The pin cohort keeps ordinal order even when papers/photos interleave
    // as visited locations enter their unlocked drawing layer.
    result.reason="map-pin-cohort";
    int next=0;
    for(size_t i=0;i<24;++i) {
        if(next==result.selected)++next;
        const int ordinal=i==23?result.selected:next++;
        const int inRegion=ordinal>=20?ordinal-19:ordinal%5;
        const auto expected=inRegion==3?MapProfile::RedPin:inRegion==4?MapProfile::SkullPin:MapProfile::BluePin;
        if(profiles[pins[i]]!=expected)return result;
        const auto b=MapBounds(draws[pins[i]]);
        if(b.left==b.right&&b.top==b.bottom) {
            if(draws[pins[i]].vertices[0].color[3]!=0||!MapSameBounds(b,{320,224,320,224}))return result;
        } else result.groups[pins[i]]=ordinal;
        if((ordinal<first||ordinal>=last)&&draws[pins[i]].vertices[0].color[3]!=0)return result;
    }
    result.groups[glow]=result.selected;
    // Status glyphs belong to the paper's bottom band. Do not rely on their
    // changing count, draw order or visibility; ambiguous ownership rejects.
    result.reason="map-status-ownership";
    for(size_t i:counters) {
        result.rejectedDraw=i;
        const auto b=MapBounds(draws[i]);int owner=-1;
        if(b.left==b.right&&b.top==b.bottom) {
            if(draws[i].vertices[0].color[3]!=0)return result;
            continue;
        }
        for(int n=first;n<last;++n) {
            const auto p=cardBounds[n];const float w=p.right-p.left,h=p.bottom-p.top;
            if(b.left>=p.left+.08f*w-2&&b.right<=p.right-.05f*w+2&&
                b.top>=p.top+.65f*h-2&&b.bottom<=p.bottom+2) {
                if(owner>=0)return result;owner=n;
            }
        }
        if(owner<0) {
            // East has four cards but retains a fifth, invisible badge beyond
            // the source viewport. It is not a fifth location or earned state.
            if(result.region==4&&profiles[i]==MapProfile::Badge&&draws[i].vertices[0].color[3]==0&&
                MapSameBounds(b,{692,592,717,617},1.1f))continue;
            return result;
        }
        result.groups[i]=owner;
    }
    result.reason="map-card-envelope";
    for(size_t i=29;i<draws.size();++i) {
        const int n=result.groups[i];if(n<0||n>=24)continue;
        const auto b=MapBounds(draws[i]);
        const float ax=tile.left+kMapAnchors[n][0]*result.tileWidth;
        const float ay=tile.top+kMapAnchors[n][1]*result.tileHeight;
        if(b.left<ax-.325f*result.tileWidth||b.right>ax+.325f*result.tileWidth||
            b.top<ay-.325f*result.tileHeight||b.bottom>ay+.325f*result.tileHeight)return result;
    }
    result.reason="map-heading-geometry";
    constexpr MapSourceBounds title[]={{120,32,520,92},{88,32,120,92},{520,32,552,92}};
    const float titleShift=result.region==1?100.f:0.f;
    result.titleLeft=88+titleShift;
    for(size_t i=0;i<6;++i) {
        if(profiles[headings[i]]!=(i%3==0?MapProfile::Heading:MapProfile::HeadingCap)||
            draws[headings[i]].vertices[0].color[3]!=(i<3?1:0))return result;
        if((draws[headings[i]].vertices[0].position[0]>draws[headings[i]].vertices[1].position[0])!=(i%3==2))return result;
        if(i<3) {
            auto expected=title[i];expected.left+=titleShift;expected.right+=titleShift;
            if(!MapSameBounds(MapBounds(draws[headings[i]]),expected))return result;
            result.groups[headings[i]]=24;
        }
    }
    const auto tb=MapBounds(draws[fonts[0]]);
    if(tb.left<88+titleShift||tb.right>552+titleShift||tb.top<32||tb.bottom>93||draws[fonts[0]].vertices[0].color[3]!=1)return result;
    result.groups[fonts[0]]=24;
    result.reason="map-help-geometry";
    std::sort(hints.begin(),hints.end(),[&](size_t a,size_t b){return MapBounds(draws[a]).top<MapBounds(draws[b]).top;});
    for(size_t i=0;i<hints.size();++i) {
        const auto b=MapBounds(draws[hints[i]]);
        if(b.left<430||b.right>530||!MapNear(b.bottom-b.top,32)||
            !(MapNear(b.top,308)||MapNear(b.top,336)||MapNear(b.top,364))||
            draws[hints[i]].vertices[0].color[3]!=1)return result;
        if(i&&b.top<=result.hints[i-1].top)return result;
        result.hints[i]=b;result.groups[hints[i]]=25+(int)i;
    }
    result.hintCount=hints.size();result.enabled=true;result.reason="complete-regional-overview";
    return result;
}

struct MapLayoutPlan {
    bool enabled=false;
    CGSize viewport=CGSizeZero;
    CGRect title=CGRectZero,cards=CGRectZero,hints=CGRectZero;
    std::array<CGPoint,24> centers{};
    float cardScale=0;
    std::array<CGRect,24> envelopes{};
    std::array<CGRect,3> helpFrames{};
};
static NSArray* MapRectArray(CGRect r) {
    return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];
}

static bool MapValidRect(CGRect r,CGSize viewport) {
    return std::isfinite(r.origin.x)&&std::isfinite(r.origin.y)&&
        std::isfinite(r.size.width)&&std::isfinite(r.size.height)&&
        r.origin.x>=0&&r.origin.y>=0&&r.size.width>0&&r.size.height>0&&
        CGRectGetMaxX(r)<=viewport.width+.01&&CGRectGetMaxY(r)<=viewport.height+.01;
}
static MapLayoutPlan PlanMapLayout(const MapLayoutAdmission& a,CGSize viewport,
    CGRect title,CGRect cards,CGRect hints) {
    MapLayoutPlan p;
    if(!a.enabled||!std::isfinite(viewport.width)||!std::isfinite(viewport.height)||
        viewport.width<=0||viewport.height<=0||!MapValidRect(title,viewport)||
        !MapValidRect(cards,viewport)||!MapValidRect(hints,viewport)||
        CGRectIntersectsRect(title,cards)||CGRectIntersectsRect(title,hints)||
        CGRectIntersectsRect(cards,hints))return p;
    p.viewport=viewport;p.title=title;p.cards=cards;p.hints=hints;
    if(a.country) {
        // Reserve the lower-middle gap after the actual stick/action bounds,
        // ending before the Gulf marker. Keep geography, pins and help fixed.
        const float right=std::min(CGRectGetMaxX(hints),viewport.width*.55);
        const float height=std::min(72.f,std::max(36.f,float(viewport.height*.07)));
        const float scale=std::min(float((right-hints.origin.x)/(464*14.f/15)),height/a.titleHeight);
        if(scale<=0)return MapLayoutPlan{};
        const float width=464*14.f/15*scale,h=a.titleHeight*scale;
        p.title=CGRectMake((hints.origin.x+right-width)/2,CGRectGetMaxY(hints)-h,width,h);
        p.cards=CGRectZero;p.hints=CGRectZero;p.enabled=true;
        return p;
    }
    const int first=a.region*5,last=std::min(first+5,24);
    const float aspect=a.tileWidth*14.f/15/a.tileHeight;
    // Separate maximum selected envelopes, not current focus-sized paper.
    // This local card scale is identical for every location in the region.
    float shrink=1;
    for(int i=first;i<last;++i)for(int j=i+1;j<last;++j) {
        const float dx=std::abs(kMapAnchors[i][0]-kMapAnchors[j][0]);
        const float dy=std::abs(kMapAnchors[i][1]-kMapAnchors[j][1]);
        shrink=std::min(shrink,std::max(dx,dy)/.73f);
    }
    const float half=.325f*shrink;
    float left=INFINITY,right=-INFINITY,top=INFINITY,bottom=-INFINITY;
    for(int i=first;i<last;++i) {
        left=std::min(left,(kMapAnchors[i][0]-half)*aspect);
        right=std::max(right,(kMapAnchors[i][0]+half)*aspect);
        top=std::min(top,kMapAnchors[i][1]-half);
        bottom=std::max(bottom,kMapAnchors[i][1]+half);
    }
    const float fit=std::min(cards.size.width/(right-left),cards.size.height/(bottom-top));
    p.cardScale=fit*shrink/a.tileHeight;
    for(int i=0;i<24;++i) {
        p.centers[i]=CGPointMake(CGRectGetMidX(cards)+(kMapAnchors[i][0]*aspect-(left+right)/2)*fit,
            CGRectGetMidY(cards)+(kMapAnchors[i][1]-(top+bottom)/2)*fit);
        p.envelopes[i]=CGRectMake(p.centers[i].x-half*aspect*fit,p.centers[i].y-half*fit,
            2*half*aspect*fit,2*half*fit);
    }
    // Fit the original title component without changing its paper/letter ratio.
    const float titleScale=std::min(title.size.width/(464*14.f/15),title.size.height/60);
    p.title=CGRectMake(CGRectGetMidX(title)-464*14.f/15*titleScale/2,
        CGRectGetMidY(title)-60*titleScale/2,464*14.f/15*titleScale,60*titleScale);
    float helpWidth=0;
    for(size_t i=0;i<a.hintCount;++i)helpWidth+=(a.hints[i].right-a.hints[i].left)*14.f/15;
    const float gap=12;
    const float helpScale=std::min((hints.size.width-gap*(a.hintCount-1))/helpWidth,hints.size.height/32);
    if(helpScale<=0)return MapLayoutPlan{};
    float x=CGRectGetMidX(hints)-(helpWidth*helpScale+gap*(a.hintCount-1))/2;
    for(size_t i=0;i<a.hintCount;++i) {
        const float width=(a.hints[i].right-a.hints[i].left)*14.f/15*helpScale;
        p.helpFrames[i]=CGRectMake(x,CGRectGetMidY(hints)-16*helpScale,width,32*helpScale);
        x+=width+gap;
    }
    p.enabled=true;return p;
}

static void TransformMapVertex(LiveVertex* v,int group,const MapLayoutAdmission& a,const MapLayoutPlan& p) {
    if(!v||!p.enabled||group<0||group>27)return;
    float x=(v->position[0]+1)*320,y=(1-v->position[1])*224;
    if(group<24) {
        x=p.centers[group].x+(x-a.tileX-kMapAnchors[group][0]*a.tileWidth)*14.f/15*p.cardScale;
        y=p.centers[group].y+(y-a.tileY-kMapAnchors[group][1]*a.tileHeight)*p.cardScale;
    } else if(group==24) {
        x=p.title.origin.x+(x-a.titleLeft)/464*p.title.size.width;
        y=p.title.origin.y+(y-a.titleTop)/a.titleHeight*p.title.size.height;
    } else {
        const size_t hint=group-25;if(hint>=a.hintCount)return;
        const auto src=a.hints[hint];const auto dest=p.helpFrames[hint];
        x=dest.origin.x+(x-src.left)/(src.right-src.left)*dest.size.width;
        y=dest.origin.y+(y-src.top)/(src.bottom-src.top)*dest.size.height;
    }
    // Host upload only. Depth, UVs, color, alpha, original snapshot and guest
    // coordinates are never changed by layout.
    v->position[0]=x/p.viewport.width*2-1;v->position[1]=1-y/p.viewport.height*2;
}

struct MapDetailBackdropPlan {
    bool enabled=false;
    CGSize viewport=CGSizeZero;
    float scale=0,offsetX=0,offsetY=0;
};
static MapDetailBackdropPlan PlanMapDetailBackdrop(const std::vector<LiveDraw>& draws,
    bool knownWorldMap,CGSize viewport) {
    MapDetailBackdropPlan p;
    if(!knownWorldMap||draws.size()<100||draws.size()>192||viewport.width<=0||viewport.height<=0||
        !MapNear(draws[0].vertices[0].color[0],127.f/255,.00001f))return p;
    // Only the dimmed, complete map behind a settled detail panel qualifies.
    // Its regional highlights are hidden, never reposition a live selection.
    for(size_t i=24;i<29;++i) {
        const auto& d=draws[i];const auto& expected=kMapTextures[i-24];
        if(!MapQuad(d)||d.fragment.stageCount!=2||d.vertices[0].color[3]!=0||
            ![InterfaceTextureKey(TexturePixels(d,0),d.textureWidths[0],d.textureHeights[0]) isEqualToString:@(expected.primary)]||
            ![InterfaceTextureKey(TexturePixels(d,1),d.textureWidths[1],d.textureHeights[1]) isEqualToString:@(expected.auxiliary)])return p;
    }
    bool panel=false;
    for(size_t i=29;i<draws.size();++i) {
        const auto& d=draws[i];
        if(!MapSameBounds(MapBounds(d),{326,20,633,427})||!MapQuad(d)||d.fragment.stageCount!=2||
            !MapNear(d.vertices[0].color[3],127.f/255,.00001f))continue;
        const auto& expected=kMapTextures[9]; // DetailPanel exact color/matte tuple.
        if(![InterfaceTextureKey(TexturePixels(d,0),d.textureWidths[0],d.textureHeights[0]) isEqualToString:@(expected.primary)]||
            ![InterfaceTextureKey(TexturePixels(d,1),d.textureWidths[1],d.textureHeights[1]) isEqualToString:@(expected.auxiliary)])continue;
        if(panel)return MapDetailBackdropPlan{};panel=true;
    }
    if(!panel)return p;
    const auto first=MapBounds(draws[0]),last=MapBounds(draws[19]);
    const float left=first.left*14.f/15,right=last.right*14.f/15;
    p.scale=std::max({float(viewport.height/448),float(viewport.width/(right-left)),
        float(viewport.height/(last.bottom-first.top))});
    // Keep the original backdrop camera wherever it already fills the view;
    // otherwise use the smallest translation which moves its finite edge out.
    p.offsetX=std::max(float(viewport.width)-right*p.scale,
        std::min(float(viewport.width/2)-320*14.f/15*p.scale,-left*p.scale));
    p.offsetY=std::max(float(viewport.height)-last.bottom*p.scale,
        std::min(float(viewport.height/2)-224*p.scale,-first.top*p.scale));
    p.viewport=viewport;p.enabled=true;return p;
}
static void TransformMapDetailBackdrop(LiveVertex* v,const MapDetailBackdropPlan& p) {
    const float x=(v->position[0]+1)*320*14.f/15*p.scale+p.offsetX;
    const float y=(1-v->position[1])*224*p.scale+p.offsetY;
    v->position[0]=x/p.viewport.width*2-1;v->position[1]=1-y/p.viewport.height*2;
}

