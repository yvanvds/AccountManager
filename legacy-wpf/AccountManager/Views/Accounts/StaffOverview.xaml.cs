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

namespace AccountManager.Views.Accounts
{
    /// <summary>
    /// Interaction logic for StaffOverview.xaml
    /// </summary>
    public partial class StaffOverview : UserControl
    {
        public StaffOverview()
        {
            InitializeComponent();
            DataContext = new ViewModels.Accounts.StaffOverview();
        }
    }
}
