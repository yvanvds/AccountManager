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
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Dashboard
{
    /// <summary>
    /// Interaction logic for DashboardPage.xaml
    /// </summary>
    public partial class DashboardPage : UserControl
    {
        public Prop<bool> ShowLinkButtonIndicator { get; set; } = new Prop<bool> { Value = false };
        public Data Data { get => Data.Instance; }

        public Prop<string> TotalWisaGroups { get; set; } = new Prop<string> { Value = "n/a" };
        public Prop<string> TotalSmartschoolGroups { get; set; } = new Prop<string> { Value = "n/a" };
        public Prop<string> TotalDirectoryGroups { get; set; } = new Prop<string> { Value = "n/a" };

        public Prop<string> UnlinkedWisaGroups { get; set; } = new Prop<string> { Value = "n/a" };
        public Prop<string> UnlinkedSmartschoolGroups { get; set; } = new Prop<string> { Value = "n/a" };
        public Prop<string> UnlinkedDirectoryGroups { get; set; } = new Prop<string> { Value = "n/a" };

        public Prop<string> LinkedWisaGroups { get; set; } = new Prop<string> { Value = "n/a" };
        public Prop<string> LinkedSmartschoolGroups { get; set; } = new Prop<string> { Value = "n/a" };
        public Prop<string> LinkedDirectoryGroups { get; set; } = new Prop<string> { Value = "n/a" };

        public DashboardPage()
        {
            InitializeComponent();
            DataContext = this;
            updateValues();
        }

        private async void LinkButton_Click(object sender, RoutedEventArgs e)
        {
            ShowLinkButtonIndicator.Value = true;
            await LinkedGroups.ReLink();
            updateValues();
            ShowLinkButtonIndicator.Value = false;
        }

        private void updateValues()
        {
            TotalWisaGroups.Value = LinkedGroups.TotalWisaGroups.ToString();
            TotalSmartschoolGroups.Value = LinkedGroups.TotalSmartschoolGroups.ToString();
            TotalDirectoryGroups.Value = LinkedGroups.TotalDirectoryGroups.ToString();

            UnlinkedDirectoryGroups.Value = LinkedGroups.UnlinkedDirectoryGroups.ToString();
            UnlinkedSmartschoolGroups.Value = LinkedGroups.UnlinkedSmartschoolGroups.ToString();
            UnlinkedWisaGroups.Value = LinkedGroups.UnlinkedWisaGroups.ToString();

            LinkedDirectoryGroups.Value = LinkedGroups.LinkedDirectoryGroups.ToString();
            LinkedSmartschoolGroups.Value = LinkedGroups.LinkedSmartschoolGroups.ToString();
            LinkedWisaGroups.Value = LinkedGroups.LinkedWisaGroups.ToString();

            UnlinkedDirectoryLabel.Foreground = new SolidColorBrush(LinkedGroups.UnlinkedDirectoryGroups == 0 ? Colors.DarkGreen : Colors.DarkRed);
            UnlinkedSmartschoolLabel.Foreground = new SolidColorBrush(LinkedGroups.UnlinkedSmartschoolGroups == 0 ? Colors.DarkGreen : Colors.DarkRed);
            UnlinkedWisaLabel.Foreground = new SolidColorBrush(LinkedGroups.UnlinkedWisaGroups == 0 ? Colors.DarkGreen : Colors.DarkRed);

        }
    }
}
