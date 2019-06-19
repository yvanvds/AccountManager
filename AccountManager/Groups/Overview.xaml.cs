using AccountManager.Action;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Groups
{
    /// <summary>
    /// Interaction logic for Overview.xaml
    /// </summary>
    public partial class Overview : UserControl
    {
        public ObservableCollection<LinkedGroup> Groups = new ObservableCollection<LinkedGroup>();
        Prop<LinkedGroup> SelectedGroup = new Prop<LinkedGroup>() { Value = null };
        public ObservableCollection<GroupAction> Actions = new ObservableCollection<GroupAction>();
        private bool showGoodGroups = true;

        public Overview()
        {
            InitializeComponent();
            CreateCollection();
            GroupList.ItemsSource = Groups;
            DataContext = this;
        }

        private void CreateCollection()
        {
            Groups.Clear();
            List<LinkedGroup> groups = LinkedGroups.List.Values.ToList();
            groups.Sort((a, b) => a.Name.CompareTo(b.Name));
            foreach(var group in groups)
            {
                if (showGoodGroups) Groups.Add(group);
                else if (!group.GroupOK) Groups.Add(group);
            }
        }

        private void GroupList_SelectedCellsChanged(object sender, SelectedCellsChangedEventArgs e)
        {
            if(GroupList.SelectedItem is LinkedGroup)
            {
                SelectedGroup.Value = GroupList.SelectedItem as LinkedGroup;
                ActionsBox.Header = SelectedGroup.Value.Name + " - Mogelijke Acties";
                Actions.Clear();
                foreach(var action in SelectedGroup.Value.Actions)
                {
                    Actions.Add(action);
                }
                if(Actions.Count == 0)
                {
                    Actions.Add(new NoActionNeeded());
                }
            }
            else
            {
                ActionsBox.Header = "Selecteer een Klas";
                SelectedGroup.Value = null;
                Actions.Clear();
            }
            ActionsViewer.ItemsSource = Actions;
        }

        private void CheckGoodEntries_Checked(object sender, RoutedEventArgs e)
        {
            showGoodGroups = true;
            CreateCollection();
        }

        private void CheckGoodEntries_Unchecked(object sender, RoutedEventArgs e)
        {
            showGoodGroups = false;
            CreateCollection();
        }

        private async void ActionButton_Click(object sender, RoutedEventArgs e)
        {
            GroupAction action = (e.Source as Button).DataContext as GroupAction;
            action.InProgress.Value = true;
            await action.Apply(SelectedGroup.Value);
            await LinkedGroups.ReLink();
            CreateCollection();
            action.InProgress.Value = false;
        }
    }
}
