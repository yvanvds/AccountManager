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

namespace AccountManager.Views.Actions
{
    /// <summary>
    /// Interaction logic for TestButtonAction.xaml
    /// </summary>
    public partial class TestButtonAction : UserControl
    {
        public TestButtonAction()
        {
            InitializeComponent();
            DataContext = new ViewModels.Actions.TestButtonAction();
        }
    }
}
