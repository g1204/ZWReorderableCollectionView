#import "ZWReorderableCollectionView.h"

@interface ZWReorderableCollectionView () <UICollectionViewDataSource, UICollectionViewDelegate>

@property (nonatomic, weak, nullable) id<ZWReorderableCollectionViewDataSource> originDataSource;
@property (nonatomic, weak, nullable) id<ZWReorderableCollectionViewDelegate> originDelegate;

@property (nonatomic, readonly) BOOL isDraggingCell;
@property (nonatomic, strong) UIView *movingCellSnapshotView;
@property (nonatomic, strong, nullable) NSArray<NSIndexPath *> *indexPathsForDraggingCells;
@property (nonatomic, strong, nullable) NSIndexPath *indexPathForPlaceholderCell; // a transparent cell showing insert position while dragging
@property (nonatomic, strong, nullable) NSIndexPath *originalIndexPathForPlaceholderCell;

// auto scroll
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic) CGFloat autoscrollSpeed;
@property (nonatomic) BOOL isAutoscrollDown;

@end

@implementation ZWReorderableCollectionView

@dynamic dataSource;
@dynamic delegate;

static NSString *const reuseIDForPlaceholderCell = @"placeholderCell";
static NSMutableIndexSet *indexSetFromIndexPaths(NSArray<NSIndexPath *> *indexPaths);
static NSMutableArray<NSIndexPath *> *indexPathsFromRange(NSRange range);

- (instancetype)initWithFrame:(CGRect)frame collectionViewLayout:(UICollectionViewLayout *)layout {
    self = [super initWithFrame:frame collectionViewLayout:layout];
    if (self) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPressGesture:)];
        longPress.delaysTouchesBegan = YES;
        longPress.minimumPressDuration = 0.3f;
        [self addGestureRecognizer:longPress];
        self.autoscrollSpeed = 200.0f;
        self.indexPathForPlaceholderCell = nil;
        self.originalIndexPathForPlaceholderCell = nil;
        self.indexPathsForDraggingCells = nil;
        [self registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:reuseIDForPlaceholderCell];
    }
    return self;
}

- (void)setDataSource:(id<ZWReorderableCollectionViewDataSource>)dataSource {
    self.originDataSource = dataSource;
    [super setDataSource:self];
}

- (void)setDelegate:(id<ZWReorderableCollectionViewDelegate>)delegate {
    self.originDelegate = delegate;
    [super setDelegate:self];
}

- (BOOL)isDraggingCell {
    return self.indexPathsForDraggingCells.count > 0;
}

- (void)handleLongPressGesture:(UILongPressGestureRecognizer *)gesutre {
    CGPoint pos = [gesutre locationInView:self];
    switch (gesutre.state) {
    case UIGestureRecognizerStateBegan: {
        NSIndexPath *currentIndexPath = [self indexPathForItemAtPoint:pos];
        if (currentIndexPath) {
            UICollectionViewCell *cell = [self cellForItemAtIndexPath:currentIndexPath];
            [self setupSnapshotViewOfMovingCellAtIndexPath:currentIndexPath withGestureRecognizer:gesutre];
            {
                self.originalIndexPathForPlaceholderCell = currentIndexPath;

                if (!cell.selected) {
                    [self selectItemAtIndexPath:currentIndexPath animated:NO scrollPosition:UICollectionViewScrollPositionNone];
                }
                NSArray<NSIndexPath *> *selectedIndexPaths = self.indexPathsForSelectedItems;
                self.indexPathsForDraggingCells = selectedIndexPaths;
                assert(!self.indexPathForPlaceholderCell);
                [self deleteItemsAtIndexPaths:selectedIndexPaths];

                self.indexPathForPlaceholderCell = [self indexPathForItemAtPoint:pos] ?: ({
                    NSIndexPath *lastIndexPath = [self indexPathForLastVisibleItem];
                    lastIndexPath
                        ? [NSIndexPath indexPathForItem:lastIndexPath.item + 1 inSection:0]
                        : [NSIndexPath indexPathForItem:0 inSection:0];
                });
                [self insertItemsAtIndexPaths:@[ self.indexPathForPlaceholderCell ]];
            }
        }
    } break;

    case UIGestureRecognizerStateChanged: {
        self.movingCellSnapshotView.center = pos;
        if (!self.indexPathForPlaceholderCell)
            break;
        NSIndexPath *newIndexPath = [self indexPathForItemAtPoint:pos];
        if (newIndexPath && ![newIndexPath isEqual:self.indexPathForPlaceholderCell]) {
            NSIndexPath *oldIndexPath = self.indexPathForPlaceholderCell;
            self.indexPathForPlaceholderCell = newIndexPath;
            [self performBatchUpdates:^{
                [self moveItemAtIndexPath:oldIndexPath toIndexPath:newIndexPath];
            }
                           completion:nil];
        }

        if (self.visibleCells.count == 0)
            break;
        //autoscroll
        CGFloat cellHeight = self.visibleCells[0].contentView.bounds.size.height;
        if (pos.y - self.contentOffset.y < cellHeight && self.contentOffset.y > 1e-3) {
            [self autoscrollUp];
        } else if (pos.y - self.contentOffset.y > self.bounds.size.height - cellHeight) {
            [self autoscrollDown];
        } else {
            [self stopAutoscroll];
        }
    } break;

    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled: {
        if (!self.indexPathForPlaceholderCell)
            break;
        self.movingCellSnapshotView.center = pos;
        NSUInteger destinationIndex = ([self indexPathForItemAtPoint:pos] ?: self.indexPathForPlaceholderCell).item;

        NSUInteger originalDestinationIndex = destinationIndex == 0 ? 0
                                                                    : [self getOriginalIndexPathForIndexPath:[NSIndexPath indexPathForItem:destinationIndex - 1 inSection:0]].item + 1;
        NSMutableArray<NSIndexPath *> *sourceIndexPaths = self.indexPathsForDraggingCells.copy;
        [self.originDelegate reorderableCollectionView:self willMoveItemsAtIndexPaths:sourceIndexPaths toIndex:originalDestinationIndex];
        [self.originDataSource reorderableCollectionView:self moveItemsAtIndexPaths:sourceIndexPaths toIndex:originalDestinationIndex];

        NSIndexPath *indexPathForPlaceholderCell = self.indexPathForPlaceholderCell;
        self.indexPathForPlaceholderCell = nil;
        self.originalIndexPathForPlaceholderCell = nil;
        [self deleteItemsAtIndexPaths:@[ indexPathForPlaceholderCell ]];

        NSUInteger numDraggingCells = self.indexPathsForDraggingCells.count;
        self.indexPathsForDraggingCells = nil;
        [self insertItemsAtIndexPaths:indexPathsFromRange(NSMakeRange(destinationIndex, numDraggingCells))];

        [self tearDownSnapshotViewOfMovingCellAtIndexPath:[NSIndexPath indexPathForItem:destinationIndex inSection:0]
                                               completion:^{
                                                   [self.originDelegate reorderableCollectionView:self didMoveItemsAtIndexPaths:sourceIndexPaths toIndex:originalDestinationIndex];
                                               }];
        [self stopAutoscroll];
    } break;

    default:
        break;
    }
}

- (NSIndexPath *)indexPathForLastVisibleItem {
    __block NSIndexPath *lastIndexPath = nil;
    [self.indexPathsForVisibleItems enumerateObjectsUsingBlock:^(NSIndexPath *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
        if (!lastIndexPath || lastIndexPath.item < obj.item) {
            lastIndexPath = obj;
        }
    }];
    return lastIndexPath;
}

- (void)setupSnapshotViewOfMovingCellAtIndexPath:(NSIndexPath *)indexPath withGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer {
    UICollectionViewCell *cell = [self cellForItemAtIndexPath:indexPath];
    assert(cell);
    if (!cell) {
        return;
    }
    UIView *snapshotView = [cell.contentView snapshotViewAfterScreenUpdates:NO];
    snapshotView.center = cell.center;
    int selectedCount = (int) self.indexPathsForSelectedItems.count;
    if (selectedCount > 1) {
        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont systemFontOfSize:15];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor clearColor];
        label.text = [NSString stringWithFormat:@"%d", selectedCount];
        [label sizeToFit];
        label.center = CGPointMake(CGRectGetMaxX(snapshotView.bounds), 0);
        [snapshotView addSubview:label];
        [snapshotView sizeToFit];
    }

    [UIView animateWithDuration:0.3
        delay:0.0
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:^{
            snapshotView.alpha = 0.7;
            snapshotView.transform = CGAffineTransformMakeScale(1.1, 1.1);
            snapshotView.layer.shadowOpacity = 0.7;
            snapshotView.center = [gestureRecognizer locationInView:self];
        }
        completion:^(BOOL finished) {
            if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
                snapshotView.center = [gestureRecognizer locationInView:self];
            }
        }];

    [self addSubview:snapshotView];
    self.movingCellSnapshotView = snapshotView;
}

- (void)tearDownSnapshotViewOfMovingCellAtIndexPath:(NSIndexPath *)indexPath completion:(void (^)(void))completion {
    UICollectionViewCell *cell = [self cellForItemAtIndexPath:indexPath];
    cell.contentView.alpha = 0.0f;
    [UIView animateWithDuration:0.3
        delay:0
        options:0
        animations:^{
            self.movingCellSnapshotView.transform = CGAffineTransformIdentity;
            if (cell) {
                self.movingCellSnapshotView.frame = (CGRect){cell.frame.origin, self.movingCellSnapshotView.frame.size};
            }
            cell.contentView.alpha = 0.5f;
        }
        completion:^(BOOL finished) {
            [self.movingCellSnapshotView removeFromSuperview];
            self.movingCellSnapshotView = nil;
            cell.contentView.alpha = 1.0f;
            if (completion) {
                completion();
            }
        }];
}

- (NSIndexPath *_Nonnull)getOriginalIndexPathForIndexPath:(NSIndexPath *_Nonnull)indexPath {
    if (!self.isDraggingCell) {
        return indexPath;
    }
    if ([indexPath isEqual:self.indexPathForPlaceholderCell]) {
        return self.originalIndexPathForPlaceholderCell;
    }
    NSUInteger originIndex = 0;
    NSUInteger index = NSNotFound;
    NSIndexSet *indexSet = indexSetFromIndexPaths(self.indexPathsForDraggingCells);
    while (1) {
        if (![indexSet containsIndex:originIndex]) {
            index = index == NSNotFound ? 0 : (index + 1);
            // ignore placeholder cell
            if (self.indexPathForPlaceholderCell && index == self.indexPathForPlaceholderCell.item) {
                index++;
            }
            if (index == indexPath.item) {
                return [NSIndexPath indexPathForItem:originIndex inSection:0];
            }
        }
        originIndex++;
    }
}

#pragma mark autoscroll

- (void)autoscrollDown {
    [self autoscrollWithIsAutoscrollDown:YES];
}

- (void)autoscrollUp {
    [self autoscrollWithIsAutoscrollDown:NO];
}

- (void)autoscrollWithIsAutoscrollDown:(BOOL)isAutoscrollDown {
    if (self.displayLink && !self.displayLink.paused && isAutoscrollDown == self.isAutoscrollDown) {
        return;
    }
    [self stopAutoscroll];
    //    NSLog(@"begin autoscrolling");
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleAutoscroll:)];
    self.isAutoscrollDown = isAutoscrollDown;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopAutoscroll {
    if (self.displayLink) {
        //        NSLog(@"end autoscrolling");
        if (!self.displayLink.paused) {
            [self.displayLink invalidate];
        }
        self.displayLink = nil;
    }
}

- (void)handleAutoscroll:(CADisplayLink *)displayLink {
    CGFloat translationY = (self.isAutoscrollDown ? 1.0f : -1.0f) * self.autoscrollSpeed * displayLink.duration;
    translationY = rint(translationY);
    if (translationY + self.contentOffset.y < 0) {
        translationY = -self.contentOffset.y;
    }
    CGFloat maxY = MAX(self.contentSize.height, self.bounds.size.height);
    if (translationY + self.contentOffset.y > maxY - self.bounds.size.height) {
        translationY = maxY - self.bounds.size.height - self.contentOffset.y;
    }

    self.movingCellSnapshotView.center = ({
        CGPoint center = self.movingCellSnapshotView.center;
        center.y += translationY;
        center;
    });
    self.contentOffset = ({
        CGPoint cntentOffset = self.contentOffset;
        cntentOffset.y += translationY;
        cntentOffset;
    });
}

#pragma mark <UICollectionViewDataSource>

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return [self.originDataSource collectionView:collectionView numberOfItemsInSection:section] - self.indexPathsForDraggingCells.count + (self.indexPathForPlaceholderCell ? 1 : 0);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if ([indexPath isEqual:self.indexPathForPlaceholderCell]) {
        return [collectionView dequeueReusableCellWithReuseIdentifier:reuseIDForPlaceholderCell forIndexPath:indexPath];
    }
    indexPath = [self getOriginalIndexPathForIndexPath:indexPath];
    return [self.originDataSource collectionView:collectionView cellForItemAtIndexPath:indexPath];
}

#pragma mark <FSReorderableCollectionViewReorderDelegate>

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    if ([indexPath isEqual:self.indexPathForPlaceholderCell]) {
        return;
    }
    indexPath = [self getOriginalIndexPathForIndexPath:indexPath];
    return [self.originDelegate collectionView:collectionView willDisplayCell:cell forItemAtIndexPath:indexPath];
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    if ([indexPath isEqual:self.indexPathForPlaceholderCell]) {
        return;
    }
    indexPath = [self getOriginalIndexPathForIndexPath:indexPath];
    return [self.originDelegate collectionView:collectionView didEndDisplayingCell:cell forItemAtIndexPath:indexPath];
}

// for other methods of UICollectionViewDelegate, just pass to original delegate

- (BOOL)collectionView:(UICollectionView *)collectionView shouldSelectItemAtIndexPath:(nonnull NSIndexPath *)indexPath {
    return [self.originDelegate collectionView:collectionView shouldSelectItemAtIndexPath:indexPath];
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    return [self.originDelegate collectionView:collectionView didSelectItemAtIndexPath:indexPath];
}

- (void)collectionView:(UICollectionView *)collectionView didDeselectItemAtIndexPath:(nonnull NSIndexPath *)indexPath {
    return [self.originDelegate collectionView:collectionView didDeselectItemAtIndexPath:indexPath];
}

// add other methods...

@end

static NSMutableIndexSet *indexSetFromIndexPaths(NSArray<NSIndexPath *> *indexPaths) {
    NSMutableIndexSet *indexSet = [NSMutableIndexSet indexSet];
    for (NSIndexPath *indexPath in indexPaths) {
        [indexSet addIndex:indexPath.item];
    }
    return indexSet;
}

static NSMutableArray<NSIndexPath *> *indexPathsFromRange(NSRange range) {
    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray<NSIndexPath *> arrayWithCapacity:range.length];
    for (NSUInteger i = range.location; i < range.location + range.length; i++) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:0]];
    }
    return indexPaths;
}
