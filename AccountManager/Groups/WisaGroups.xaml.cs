using System;
using System.Collections.Generic;
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
using static Utils.ObservableProperties;

namespace AccountManager.Groups
{
    /// <summary>
    /// Interaction logic for WisaGroups.xaml
    /// </summary>
    public partial class WisaGroups : UserControl
    {
        public Prop<bool> ShowGroupsReloadButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Prop<string> GroupCount { get; set; } = new Prop<string> { Value = "0" };
        public Data Data { get => Data.Instance; }

        public WisaGroups()
        {
            InitializeComponent();
            MainGrid.DataContext = this;
            GroupList.ItemsSource = WisaApi.ClassGroups.All;
        }

        private async void ReloadGroupsButton_Click(object sender, RoutedEventArgs e)
        {
            ShowGroupsReloadButtonIndicator.Value = true;
            Data.Instance.SetWisaCredentials();
            await Data.Instance.ReloadWisaClassgroups();
            GroupCount.Value = WisaApi.ClassGroups.All.Count.ToString();
            ShowGroupsReloadButtonIndicator.Value = false;
        }

        private void Calendar_MouseDoubleClick(object sender, MouseButtonEventArgs e)
        {

        }
    }
}
