using AccountManager.Action.Group;
using AccountManager.ViewModels;
using MaterialDesignThemes.Wpf;
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

namespace AccountManager.Views.Groups
{
    /// <summary>
    /// Interaction logic for Overview.xaml
    /// </summary>
    public partial class Overview : UserControl
    {
        public ObservableCollection<State.Linked.LinkedGroup> Groups = new ObservableCollection<State.Linked.LinkedGroup>();
        Prop<State.Linked.LinkedGroup> SelectedGroup = new Prop<State.Linked.LinkedGroup>() { Value = null };
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
            List<State.Linked.LinkedGroup> groups = State.App.Instance.Linked.Groups.List.Values.ToList();
            groups.Sort((a, b) => a.Name.CompareTo(b.Name));
            foreach(var group in groups)
            {
                if (showGoodGroups) Groups.Add(group);
                else if (!group.OK) Groups.Add(group);
            }
        }

        private void GroupList_SelectedCellsChanged(object sender, SelectedCellsChangedEventArgs e)
        {
            if(GroupList.SelectedItem is State.Linked.LinkedGroup)
            {
                SelectedGroup.Value = GroupList.SelectedItem as State.Linked.LinkedGroup;
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
            await action.Apply(SelectedGroup.Value).ConfigureAwait(false);
            
            await State.App.Instance.Linked.Groups.ReLink().ConfigureAwait(false);

            Application.Current.Dispatcher.Invoke(new System.Action(() => CreateCollection()));

            action.InProgress.Value = false;
        }

        private async void ShowDetails_Click(object sender, RoutedEventArgs e)
        {
            GroupAction action = (e.Source as Button).DataContext as GroupAction;

            if (action.CanShowDetails)
            {
                var document = action.GetDetails(SelectedGroup.Value);
                var dialog = new Views.Dialogs.ShowActionDetails(document);
                await DialogHost.Show(dialog, "RootDialog").ConfigureAwait(false);
            }
        }
    }
}
