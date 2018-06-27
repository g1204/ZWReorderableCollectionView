#import <UIKit/UIKit.h>

@class ZWReorderableCollectionView;

NS_ASSUME_NONNULL_BEGIN

@protocol ZWReorderableCollectionViewDataSource <UICollectionViewDataSource>

- (void)reorderableCollectionView:(ZWReorderableCollectionView *)collectionView moveItemsAtIndexPaths:(NSArray<NSIndexPath *> *)sourceIndexPaths toIndex:(NSUInteger)destinationIndex;

@end

@protocol ZWReorderableCollectionViewDelegate <UICollectionViewDelegate>

- (void)reorderableCollectionView:(ZWReorderableCollectionView *)collectionView willMoveItemsAtIndexPaths:(NSArray<NSIndexPath *> *)sourceIndexPaths toIndex:(NSUInteger)destinationIndex;
- (void)reorderableCollectionView:(ZWReorderableCollectionView *)collectionView didMoveItemsAtIndexPaths:(NSArray<NSIndexPath *> *)sourceIndexPaths toIndex:(NSUInteger)destinationIndex;

@end

// allow to select and move multiple cells simultaneously, assumed only ONE section

@interface ZWReorderableCollectionView : UICollectionView

@property (nonatomic, weak, nullable) id<ZWReorderableCollectionViewDataSource> dataSource;
@property (nonatomic, weak, nullable) id<ZWReorderableCollectionViewDelegate> delegate;

- (instancetype)initWithFrame:(CGRect)frame collectionViewLayout:(UICollectionViewLayout *)layout;

@end

NS_ASSUME_NONNULL_END
