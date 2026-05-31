#import <Foundation/Foundation.h>
#import "Tweaks.h"
#import <objc/runtime.h>

// Bundle registry: almacena rutas reales de bundles de tweaks
static NSMutableDictionary<NSString*, NSString*> *gBundleRegistry = nil;

// Inicializar registry
static void initBundleRegistry(void) {
    if (!gBundleRegistry) {
        gBundleRegistry = [[NSMutableDictionary alloc] init];
    }
}

// Función pública para que TweakLoader registre bundles descubiertos
void registerTweakBundle(NSString *bundleName, NSString *bundlePath) {
    initBundleRegistry();
    if (bundleName && bundlePath) {
        gBundleRegistry[bundleName] = bundlePath;
        NSLog(@"[LC] Registered tweak bundle: %@ → %@", bundleName, bundlePath);
    }
}

// Hook para +[NSBundle bundleWithPath:]
@implementation NSBundle (TweakBundles)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        initBundleRegistry();
        
        Class cls = NSBundle.class;
        
        // Hook 1: bundleWithPath:
        SEL originalSel = @selector(bundleWithPath:);
        SEL newSel = @selector(lc_bundleWithPath:);
        
        Method originalMethod = class_getClassMethod(cls, originalSel);
        Method newMethod = class_getClassMethod(cls, newSel);
        
        if (originalMethod && newMethod) {
            method_exchangeImplementations(originalMethod, newMethod);
            NSLog(@"[LC] Hooked +[NSBundle bundleWithPath:]");
        }
        
        // Hook 2: pathForResource:ofType:inDirectory:forLocalization: (instance method)
        SEL originalInstSel = @selector(pathForResource:ofType:inDirectory:forLocalization:);
        SEL newInstSel = @selector(lc_pathForResource:ofType:inDirectory:forLocalization:);
        
        Method originalInstMethod = class_getInstanceMethod(cls, originalInstSel);
        Method newInstMethod = class_getInstanceMethod(cls, newInstSel);
        
        if (originalInstMethod && newInstMethod) {
            method_exchangeImplementations(originalInstMethod, newInstMethod);
            NSLog(@"[LC] Hooked -[NSBundle pathForResource:ofType:inDirectory:forLocalization:]");
        }
    });
}

// Hook de clase: interceptar +bundleWithPath: para resolver bundles desde registry
+ (NSBundle *)lc_bundleWithPath:(NSString *)path {
    // Primero intentar la ruta original
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [self lc_bundleWithPath:path];
    }
    
    // Si no existe, extraer nombre del bundle
    NSString *bundleName = path.lastPathComponent;
    
    // Buscar en registry
    NSString *registeredPath = gBundleRegistry[bundleName];
    if (registeredPath) {
        NSLog(@"[LC] Resolving bundle %@ from registry: %@", bundleName, registeredPath);
        return [self lc_bundleWithPath:registeredPath];
    }
    
    // Fallback: retornar lo que retornaría el método original (nil o bundle inválido)
    return [self lc_bundleWithPath:path];
}

// Hook de instancia: interceptar pathForResource: para buscar en tweaks
- (NSString *)lc_pathForResource:(NSString *)name ofType:(NSString *)ext inDirectory:(NSString *)subpath forLocalization:(NSString *)localization {
    // Primero intentar con el método original
    NSString *result = [self lc_pathForResource:name ofType:ext inDirectory:subpath forLocalization:localization];
    
    if (result) {
        return result;
    }
    
    // Si no encuentra el recurso y es un .bundle, busca en la carpeta de tweaks
    if ([ext isEqualToString:@"bundle"] || [name hasSuffix:@".bundle"]) {
        NSString *tweakBundleFolder = nil;
        
        // Obtén la carpeta de tweaks desde variables de entorno
        const char *globalTweaksFolder = getenv("LC_GLOBAL_TWEAKS_FOLDER");
        if (globalTweaksFolder) {
            tweakBundleFolder = @(globalTweaksFolder);
        }
        
        if (!tweakBundleFolder) {
            // Alternativa: construye la ruta desde el contenedor de la app
            NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            tweakBundleFolder = [docPath stringByAppendingPathComponent:@"Tweaks"];
        }
        
        // Busca el bundle en la carpeta de tweaks
        if (tweakBundleFolder) {
            NSString *bundleName = [ext length] > 0 ? [NSString stringWithFormat:@"%@.%@", name, ext] : name;
            NSString *bundlePath = [tweakBundleFolder stringByAppendingPathComponent:bundleName];
            
            NSFileManager *fm = NSFileManager.defaultManager;
            if ([fm fileExistsAtPath:bundlePath]) {
                NSLog(@"[LC] Found bundle in tweaks folder: %@", bundlePath);
                return bundlePath;
            }
            
            // También busca recursivamente por si está en una carpeta anidada (eg: MyTweak/MyTweak.bundle)
            NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:tweakBundleFolder];
            for (NSString *file in enumerator) {
                if ([file.lastPathComponent isEqualToString:bundleName]) {
                    NSString *fullPath = [tweakBundleFolder stringByAppendingPathComponent:file];
                    NSLog(@"[LC] Found bundle recursively in tweaks folder: %@", fullPath);
                    return fullPath;
                }
            }
        }
    }
    
    return result;
}

@end
