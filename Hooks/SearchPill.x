#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

static BOOL isSearchPillMaterial(UIView *mat) {
    if (!isExactClass(mat, @"MTMaterialView")) return NO;
    return hasAncestorOfClassName(mat, @"SBFolderScrollAccessoryView");
}

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGRegisterMaterialHost(@"SearchPill", 100, ^BOOL(UIView *material) {
        return isSearchPillMaterial(material);
    }, UIEdgeInsetsZero, ^CGFloat(UIView *material) {

        return material.layer.cornerRadius > 0.0 ? -1.0 : CGRectGetHeight(material.bounds) * 0.5;
    }, nil, nil);
}
