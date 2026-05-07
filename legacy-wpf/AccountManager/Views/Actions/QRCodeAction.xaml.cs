using System.Windows.Controls;

namespace AccountManager.Views.Actions
{
    /// <summary>
    /// Interaction logic for QRCodeAction.xaml
    /// </summary>
    public partial class QRCodeAction : UserControl
    {
        public QRCodeAction()
        {
            InitializeComponent();
            DataContext = new ViewModels.Actions.QRCodeAction();
        }
    }
}
