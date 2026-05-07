using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Windows.Controls;
using System.Windows.Data;


// extension on datagrid that will remember its sorting after the itemsource changes
namespace AccountManager.Utils
{
    public class SortKeepingDataGrid : DataGrid
    {
        // Dictionary to keep SortDescriptions per ItemSource
        private List<SortDescription> m_SortDescriptions = new List<SortDescription>();

        protected override void OnSorting(DataGridSortingEventArgs eventArgs)
        {
            base.OnSorting(eventArgs);
            UpdateSorting();
        }
        protected override void OnItemsSourceChanged(IEnumerable oldValue, IEnumerable newValue)
        {
            base.OnItemsSourceChanged(oldValue, newValue);

            ICollectionView view = CollectionViewSource.GetDefaultView(newValue);
            view.SortDescriptions.Clear();
            foreach (var sortDescription in m_SortDescriptions)
            {
                view.SortDescriptions.Add(sortDescription);

                DataGridColumn column = Columns.FirstOrDefault(c => c.SortMemberPath == sortDescription.PropertyName);
                if (column != null) column.SortDirection = sortDescription.Direction;
            }

            //// reset SortDescriptions for new ItemSource
            //if (m_SortDescriptions.ContainsKey(newValue))
            //    foreach (SortDescription sortDescription in m_SortDescriptions[newValue])
            //    {
            //        view.SortDescriptions.Add(sortDescription);

            //        // I need to tell the column its SortDirection,
            //        // otherwise it doesn't draw the triangle adornment
            //        DataGridColumn column = Columns.FirstOrDefault(c => c.SortMemberPath == sortDescription.PropertyName);
            //        if (column != null)
            //            column.SortDirection = sortDescription.Direction;
            //    }
        }

        // Store SortDescriptions in dictionary
        private void UpdateSorting()
        {
            ICollectionView view = CollectionViewSource.GetDefaultView(ItemsSource);
            m_SortDescriptions = new List<SortDescription>(view.SortDescriptions);
        }
    }
}
